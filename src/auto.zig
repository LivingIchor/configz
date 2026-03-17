const std = @import("std");
const c = @import("c.zig").git2;
const config = @import("config.zig");

const FileGroup = struct {
    dirname: ?[]const u8,
    file_set: ?std.ArrayList([]const u8),
};

const WatchEntry = struct {
    is_explicit: bool,
    file_group: FileGroup,
};

fn handleEvent(
    allocator: std.mem.Allocator,
    event: *std.os.linux.inotify_event,
    wd_hash: *std.AutoHashMap(usize, WatchEntry)
) !void {
    _ = allocator;
    _ = event;
    _ = wd_hash;
}

pub fn watchFiles(init: std.process.Init, repo: *c.git_repository) !void {
    const repo_path = c.git_repository_path(repo);

    const home = std.c.getenv("HOME").?;
    const full_path = try std.fmt.allocPrint(
        init.gpa, config.bare_repo_path_fmt ++ "/watched_dirs", .{home});

    const wdirs_handle = try std.Io.Dir.createFileAbsolute(
        init.io, full_path, .{.read = true, .truncate = false});
    var readbuf = [_]u8{0} ** 1024;
    var wdirs_reader = wdirs_handle.reader(init.io, &readbuf);
    // var writebuf = [_]u8{0} ** 1024;
    // var wdirs_writer = wdirs_handle.writer(init.io, &writebuf);

    var out_wdirs = wdirs_reader.interface;
    // var in_wdirs = wdirs_writer.interface;

    var expl_dirs = try getExplicitDirs(init.gpa, &out_wdirs);
    defer expl_dirs.deinit(init.gpa);
    defer for (expl_dirs.items) |d| init.gpa.free(d);

    var file_dirs = try getTrackedFiles(init.gpa, repo);
    defer file_dirs.deinit(init.gpa); // ArrayList(FileGroup)
    defer for (file_dirs.items) |f| { // f = FileGroup
        if (f.file_set) |set| {
            var mset = set;
            for (mset.items) |file| init.gpa.free(file);
            mset.deinit(init.gpa);
        }
        if (f.dirname) |dir| init.gpa.free(dir);
    };

    // Initialize inotify
    const ifd: i32 = @intCast(std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK));

    var wd_files = std.AutoHashMap(usize, WatchEntry).init(init.gpa);
    defer wd_files.deinit();

    // Add watches
    var wd: usize = undefined;
    for (expl_dirs.items) |dirpath| {
        wd = std.os.linux.inotify_add_watch(ifd, repo_path,
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
            std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
            std.os.linux.IN.MOVED_TO);

        const we = try init.gpa.create(WatchEntry);
        we.* = WatchEntry{
            .is_explicit = true,
            .file_group = FileGroup{
                .dirname = dirpath,
                .file_set = null,
            },
        };

        try wd_files.put(wd, we.*);
    }

    for (file_dirs.items) |group| {
        wd = std.os.linux.inotify_add_watch(ifd, repo_path,
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
            std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
            std.os.linux.IN.MOVED_TO);

        const we = try init.gpa.create(WatchEntry);
        we.* = WatchEntry{
            .is_explicit = false,
            .file_group = group,
        };

        try wd_files.put(wd, we.*);
    }

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        // Read events
        const len = std.os.linux.read(ifd, &buf, buf.len);

        // Parse events
        var offset: usize = 0;
        while (offset < len) {
            const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));

            try handleEvent(init.gpa, event, &wd_files);

            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }
    }
}

fn getExplicitDirs(
    allocator: std.mem.Allocator,
    manifest_reader: *std.Io.Reader
) !std.ArrayList([]const u8) {
    var dirs = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    while (manifest_reader.takeSentinel('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    }) |dir| {
        try dirs.append(allocator, try allocator.dupe(u8, dir));
    }

    return dirs;
}

fn getTrackedFiles(
    allocator: std.mem.Allocator,
    repo: *c.git_repository
) !std.ArrayList(FileGroup) {
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) return error.GitError;
    defer c.git_index_free(index);

    // Read latest index from disk
    _ = c.git_index_read(index, 1);

    const count = c.git_index_entrycount(index);
    var dirs = try std.ArrayList(FileGroup).initCapacity(allocator, 0);

    var entry = c.git_index_get_byindex(index, 0);
    var current_dirname: ?[]const u8 = std.fs.path.dirname(std.mem.span(entry.*.path));
    var file_set = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    try file_set.append(allocator, try allocator.dupe(
        u8, std.fs.path.basename(std.mem.span(entry.*.path))));

    var dir_group = try allocator.create(FileGroup);
    dir_group.* = FileGroup{
        .dirname = if (current_dirname) |dir| try allocator.dupe(u8, dir) else null,
        .file_set = file_set,
    };

    try dirs.append(allocator, dir_group.*);

    var i: usize = 1;
    while (i < count) : (i += 1) {
        entry = c.git_index_get_byindex(index, i);
        const new_dirname: ?[]const u8 = std.fs.path.dirname(std.mem.span(entry.*.path));

        if ((current_dirname == null and new_dirname == null)
            or ((current_dirname != null and new_dirname != null)
            and std.mem.eql(u8, current_dirname.?, new_dirname.?))
        ) {
            try file_set.append(allocator, try allocator.dupe(
                u8, std.fs.path.basename(std.mem.span(entry.*.path))));
        } else {
            current_dirname = new_dirname;
            file_set = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            try file_set.append(allocator, try allocator.dupe(
                u8, std.fs.path.basename(std.mem.span(entry.*.path))));

            dir_group = try allocator.create(FileGroup);
            dir_group.* = FileGroup{
                .dirname = if (current_dirname) |dir| try allocator.dupe(u8, dir) else null,
                .file_set = file_set,
            };

            try dirs.append(allocator, dir_group.*);
        }
    }

    return dirs;
}

const std = @import("std");
const c = @import("c.zig").git2;
const config = @import("config.zig");

pub const WatchCmd = struct {
    op: enum { add, remove },
    path: []const u8,
};

const WatchDirStat = struct {
    is_explicit: bool,
    file_set: ?std.ArrayList([]const u8),
};

fn handleEvent(
    allocator: std.mem.Allocator,
    event: *std.os.linux.inotify_event,
    wd_dirhash: *std.AutoHashMap(usize, []const u8),
    dir_stathash: *std.StringHashMap(WatchDirStat)
) !void {
    _ = allocator;
    _ = event;
    _ = wd_dirhash;
    _ = dir_stathash;
}

fn handleCmd(
    allocator: std.mem.Allocator,
    cmd: WatchCmd,
    wd_dirhash: *std.AutoHashMap(usize, []const u8),
    dir_stathash: *std.StringHashMap(WatchDirStat)
) !void {
    _ = allocator;
    _ = cmd;
    _ = wd_dirhash;
    _ = dir_stathash;
}

pub fn watchFiles(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) !void {
    const home = std.c.getenv("HOME").?;

    const repo_path = c.git_repository_path(repo);
    const wdirs_path = try std.fmt.allocPrint(
        init.gpa, "{s}/watched_dirs", .{repo_path});

    const wdirs_handle = try std.Io.Dir.createFileAbsolute(
        init.io, wdirs_path, .{.read = true, .truncate = false});
    var readbuf = [_]u8{0} ** 1024;
    var wdirs_reader = wdirs_handle.reader(init.io, &readbuf);
    // var writebuf = [_]u8{0} ** 1024;
    // var wdirs_writer = wdirs_handle.writer(init.io, &writebuf);

    var out_wdirs = wdirs_reader.interface;
    // var in_wdirs = wdirs_writer.interface;

    var expl_stats = try getExplicitDirs(init.gpa, &out_wdirs);
    var file_stats = try getTrackedFiles(init.gpa, repo);
    var it = expl_stats.iterator();
    while (it.next()) |entry| {
        try file_stats.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    expl_stats.deinit();
    defer freeEntries(init.gpa, &file_stats);

    // Initialize inotify
    const ifd: i32 = @intCast(std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK));

    var wd_dirs = std.AutoHashMap(usize, []const u8).init(init.gpa);
    defer wd_dirs.deinit();

    // Add watches
    var wd: usize = undefined;

    // Add watch for the repo itself
    wd = std.os.linux.inotify_add_watch(ifd, repo_path,
        std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
        std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.MOVED_TO);
    try wd_dirs.put(wd, std.mem.span(repo_path));

    // Add watches for all other tracked directories and files
    var statit = file_stats.iterator();
    while (statit.next()) |stat| {
        const abs_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{home, stat.key_ptr.*});
        defer init.gpa.free(abs_path);

        wd = std.os.linux.inotify_add_watch(ifd, @ptrCast(&abs_path),
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
            std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
            std.os.linux.IN.MOVED_TO);

        try wd_dirs.put(wd, stat.key_ptr.*);
    }

    var fds = [_]std.os.linux.pollfd{
        .{ .fd = ifd, .events = std.os.linux.POLL.IN, .revents = 0 },
        .{ .fd = pipe_read_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
    };

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        // Read events or recieve watch commands
        _ = std.os.linux.poll(&fds, fds.len, -1);
        if (fds[0].revents & std.os.linux.POLL.IN != 0) {
            // handle inotify events
            const len = std.os.linux.read(ifd, &buf, buf.len);

            // Parse events
            var offset: usize = 0;
            while (offset < len) {
                const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));

                try handleEvent(init.gpa, event, &wd_dirs, &file_stats);

                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }
        if (fds[1].revents & std.os.linux.POLL.IN != 0) {
            // read and handle watch command
            while (true) {
                var cmd: WatchCmd = undefined;
                const n = std.os.linux.read(pipe_read_fd, @ptrCast(&cmd), @sizeOf(WatchCmd));
                if (n == 0 or n == std.math.maxInt(usize)) break; // EAGAIN or closed

                // handle cmd
                try handleCmd(init.gpa, cmd, &wd_dirs, &file_stats);
            }
        }
    }
}

fn getExplicitDirs(
    allocator: std.mem.Allocator,
    manifest_reader: *std.Io.Reader
) !std.StringHashMap(WatchDirStat) {
    var dir_stats = std.StringHashMap(WatchDirStat).init(allocator);

    while (manifest_reader.takeSentinel('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    }) |dir| {
        const dirname = try allocator.dupe(u8, dir);
        const stat_entry = WatchDirStat{
            .is_explicit = true,
            .file_set = null,
        };
        try dir_stats.put(dirname, stat_entry);
    }

    return dir_stats;
}

fn getTrackedFiles(
    allocator: std.mem.Allocator,
    repo: *c.git_repository
) !std.StringHashMap(WatchDirStat) {
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) return error.GitError;
    defer c.git_index_free(index);

    // Read latest index from disk
    _ = c.git_index_read(index, 1);

    const count = c.git_index_entrycount(index);
    var dir_stats = std.StringHashMap(WatchDirStat).init(allocator);

    var index_entry = c.git_index_get_byindex(index, 0);
    var current_dirname: []const u8 = std.fs.path.dirname(std.mem.span(index_entry.*.path)) orelse "";
    var file_set = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    try file_set.append(allocator, try allocator.dupe(
        u8, std.fs.path.basename(std.mem.span(index_entry.*.path))));

    var stat_entry = WatchDirStat{
        .is_explicit = false,
        .file_set = file_set,
    };

    try dir_stats.put(current_dirname, stat_entry);

    var i: usize = 1;
    while (i < count) : (i += 1) {
        index_entry = c.git_index_get_byindex(index, i);
        const new_dirname: []const u8 = std.fs.path.dirname(std.mem.span(index_entry.*.path)) orelse "";

        if (std.mem.eql(u8, current_dirname, new_dirname)) {
            try file_set.append(allocator, try allocator.dupe(
                u8, std.fs.path.basename(std.mem.span(index_entry.*.path))));
        } else {
            current_dirname = new_dirname;
            file_set = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            try file_set.append(allocator, try allocator.dupe(
                u8, std.fs.path.basename(std.mem.span(index_entry.*.path))));

            stat_entry = WatchDirStat{
                .is_explicit = false,
                .file_set = file_set,
            };

            try dir_stats.put(current_dirname, stat_entry);
        }
    }

    return dir_stats;
}

fn freeEntries(allocator: std.mem.Allocator, entries: *std.StringHashMap(WatchDirStat)) void {
    defer entries.deinit();
    var it = entries.iterator();
    while (it.next()) |entry| {
        const dirname = entry.key_ptr.*;
        var watch_dir_stat = entry.value_ptr.*;

        allocator.free(dirname);

        if (watch_dir_stat.file_set) |set| {
            var mset = set;
            for (set.items) |dir| {
                allocator.free(dir);
            }
            mset.deinit(allocator);
        }
    }
}

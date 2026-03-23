const std = @import("std");
const mem = std.mem;
const c = @import("c.zig").git2;
const config = @import("config.zig");
const wtree = @import("watch-tree.zig");

pub const WatchCmd = struct {
    op: enum(u8) { add, remove },
    path_len: usize,
    path: [std.fs.max_path_bytes]u8,

    pub fn init(op: @typeInfo(@This()).@"struct".fields[0].type, path: []const u8) @This() {
        var cmd = @This(){
            .op = op,
            .path_len = path.len,
            .path = undefined,
        };
        @memcpy(cmd.path[0..path.len], path);
        return cmd;
    }

    pub fn getPath(self: *const @This()) []const u8 {
        return self.path[0..self.path_len];
    }
};

fn handleEvent(
    init: std.process.Init,
    repo: *c.git_repository,
    watches: *wtree.Paths,
    event: *std.os.linux.inotify_event,
) !void {
    std.log.debug("handleEvent: wd={d} mask={x}", .{event.wd, event.mask});

    // Look up which node this watch descriptor belongs to
    const node = watches.hashes.wd_node.get(event.wd) orelse return;

    const name = event.getName() orelse return;
    std.log.debug("handleEvent: name='{s}' wd={d}", .{name, event.wd});

    // If this node has a file_set, only act on files we care about
    if (node.watch_data.file_set) |set| {
        std.log.debug("handleEvent: checking file_set of len={d}", .{set.items.len});
        var interested = false;
        for (set.items) |file| {
            std.log.debug("handleEvent: file_set item='{s}'", .{file});
            if (std.mem.eql(u8, file, name)) {
                interested = true;
                break;
            }
        }
        if (!interested) return;
    }

    const full_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{node.abs_dirname, name});
    defer init.gpa.free(full_path);

    if (event.mask & (std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO) != 0) {
        // For whole-directory watches, only update files already in the index
        if (node.watch_data.file_set == null) {
            var index: ?*c.git_index = null;
            if (c.git_repository_index(&index, repo) != 0) return error.GitError;
            defer c.git_index_free(index);
            _ = c.git_index_read(index, 1);
            const rel_path_check = full_path[mem.span(std.c.getenv("HOME").?).len + 1..];
            const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path_check, 0);
            defer init.gpa.free(rel_path_z);
            if (c.git_index_get_bypath(index, rel_path_z, 0) == null) return;
        }

        std.log.debug("handleEvent: modified {s}", .{full_path});

        var index: ?*c.git_index = null;
        if (c.git_repository_index(&index, repo) != 0) return error.GitError;
        defer c.git_index_free(index);

        const home = mem.span(std.c.getenv("HOME").?);
        const rel_path = full_path[home.len + 1..];
        const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(rel_path_z);

        var oid: c.git_oid = undefined;
        if (c.git_blob_create_from_disk(&oid, repo, @ptrCast(full_path)) != 0)
            return error.GitError;

        var statx_buf: std.os.linux.Statx = undefined;
        _ = std.os.linux.statx(std.os.linux.AT.FDCWD, @ptrCast(full_path), 0, .BASIC_STATS, &statx_buf);

        var entry: c.git_index_entry = std.mem.zeroes(c.git_index_entry);
        entry.path = rel_path_z;
        entry.id = oid;
        entry.mode = statx_buf.mode;
        entry.file_size = @intCast(statx_buf.size);
        entry.mtime.seconds = @intCast(statx_buf.mtime.sec);
        entry.mtime.nanoseconds = @intCast(statx_buf.mtime.nsec);
        entry.ctime.seconds = @intCast(statx_buf.ctime.sec);
        entry.ctime.nanoseconds = @intCast(statx_buf.ctime.nsec);

        if (c.git_index_add(index, &entry) != 0) return error.GitError;
        if (c.git_index_write(index) != 0) return error.GitError;

    } else if (event.mask & (std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM) != 0) {
        std.log.debug("handleEvent: deleted {s}", .{full_path});

        var index: ?*c.git_index = null;
        if (c.git_repository_index(&index, repo) != 0) return error.GitError;
        defer c.git_index_free(index);

        const home = mem.span(std.c.getenv("HOME").?);
        const rel_path = full_path[home.len + 1..];
        const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(rel_path_z);

        if (c.git_index_remove_bypath(index, rel_path_z) != 0) return error.GitError;
        if (c.git_index_write(index) != 0) return error.GitError;
    }
}

fn handleCmd(
    init: std.process.Init,
    cmd: WatchCmd,
    watches: *wtree.Paths,
) !void {
    const home = mem.span(std.c.getenv("HOME").?);
    const abs_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{home, cmd.getPath()});
    defer init.gpa.free(abs_path);
    const watched_dirs = try std.fmt.allocPrint(init.gpa,
        config.bare_repo_path_fmt ++ "/watched_dirs", .{home});
    defer init.gpa.free(watched_dirs);

    if (cmd.op == .add) {
        try watches.add(init.gpa, init.io, abs_path, null);
        std.log.debug("handleCmd: adding watch for {s}", .{abs_path});
    } else { // op == .remove
        std.log.debug("handleCmd: removing watch for {s}", .{abs_path});
        try watches.remove(init.gpa, init.io, abs_path);
    }
    try watches.writeWatchedDirs(init.io, watched_dirs);
}

pub fn watchFilesWrapper(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) void {
    watchFiles(init, repo, pipe_read_fd) catch |err| {
        std.log.err("watchFiles failed: {}", .{err});
    };
}

pub fn watchFiles(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) !void {
    std.log.info("watchFiles: starting", .{});
    const home = mem.span(std.c.getenv("HOME").?);

    const repo_path = c.git_repository_path(repo);
    std.log.info("watchFiles: repo path = {s}", .{std.mem.span(repo_path)});

    const wdirs_path = try std.fmt.allocPrint(
        init.gpa, "{s}/watched_dirs", .{repo_path});
    defer init.gpa.free(wdirs_path);

    const wdirs_handle = try std.Io.Dir.createFileAbsolute(
        init.io, wdirs_path, .{.read = true, .truncate = false});
    var readbuf = [_]u8{0} ** 1024;
    var wdirs_reader = wdirs_handle.reader(init.io, &readbuf);

    var watches = try wtree.Paths.init(init.gpa, init.io, home);
    std.log.info("watchFiles: watches initialized, root = {s}", .{home});

    try addExplicitDirs(init, &watches, &wdirs_reader.interface);
    std.log.info("watchFiles: explicit dirs added", .{});

    try addTrackedFiles(init, &watches, repo);
    std.log.info("watchFiles: tracked files added", .{});

    var fds = [_]std.os.linux.pollfd{
        .{ .fd = watches.ifd, .events = std.os.linux.POLL.IN, .revents = 0 },
        .{ .fd = pipe_read_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
    };

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    std.log.info("watchFiles: entering poll loop", .{});
    while (true) {
        // Read events or recieve watch commands
        _ = std.os.linux.poll(&fds, fds.len, -1);
        if (fds[0].revents & std.os.linux.POLL.IN != 0) {
            // handle inotify events
            const len = std.os.linux.read(watches.ifd, &buf, buf.len);

            // Parse events
            var offset: usize = 0;
            while (offset < len) {
                const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));

                handleEvent(init, repo, &watches, event) catch |err| {
                    std.log.err("handleEvent failed: {}", .{err});
                };

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
                try handleCmd(init, cmd, &watches);
            }
        }
    }
}

fn addExplicitDirs(
    init: std.process.Init,
    watches: *wtree.Paths,
    manifest_reader: *std.Io.Reader
) !void {
    while (manifest_reader.takeSentinel('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    }) |dir| {
        const dirname = try init.gpa.dupe(u8, dir);
        try watches.add(init.gpa, init.io, dirname, null);
    }
}

fn addTrackedFiles(
    init: std.process.Init,
    watches: *wtree.Paths,
    repo: *c.git_repository
) !void {
    const home = mem.span(std.c.getenv("HOME").?);

    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) return error.GitError;
    defer c.git_index_free(index);

    // Read latest index from disk
    _ = c.git_index_read(index, 1);

    var i: usize = 0;
    const count = c.git_index_entrycount(index);
    while (i < count) : (i += 1) {
        const index_entry = c.git_index_get_byindex(index, i);
        const rel_path = std.mem.span(index_entry.*.path);
        const abs_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{home, rel_path});
        defer init.gpa.free(abs_path);

        try watches.add(init.gpa, init.io, abs_path, null);
    }
}

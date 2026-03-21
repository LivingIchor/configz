const std = @import("std");
const mem = std.mem;
const c = @import("c.zig").git2;
const config = @import("config.zig");
const wtree = @import("watch-tree.zig");

pub const WatchCmd = struct {
    op: enum { add, remove },
    path: []const u8,
};


fn handleEvent(
    init: std.process.Init,
    event: *std.os.linux.inotify_event,
    manifest_wd: i32,
    watches: *wtree.Paths,
) !void {
    _ = init;
    _ = event;
    _ = manifest_wd;
    _ = watches;
}

fn handleCmd(
    init: std.process.Init,
    cmd: WatchCmd,
    watches: *wtree.Paths,
) !void {
    const home = std.c.getenv("HOME").?;
    const abs_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{mem.span(home), cmd.path});
    defer init.gpa.free(abs_path);

    if (cmd.op == .add) {
        try watches.add(init.gpa, init.io, abs_path, null);

        const opened = try std.Io.Dir.openFileAbsolute(init.io, abs_path, .{});
        const statted = try opened.stat(init.io);
        if (statted.kind == .directory) {
        }
    } else { // op == .remove
        try watches.remove(init.gpa, init.io, abs_path);
    }
}

pub fn watchFiles(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) !void {
    const home = std.c.getenv("HOME").?;

    const repo_path = c.git_repository_path(repo);
    const wdirs_path = try std.fmt.allocPrint(
        init.gpa, "{s}/watched_dirs", .{repo_path});
    defer init.gpa.free(wdirs_path);

    const wdirs_handle = try std.Io.Dir.createFileAbsolute(
        init.io, wdirs_path, .{.read = true, .truncate = false});
    var readbuf = [_]u8{0} ** 1024;
    var wdirs_reader = wdirs_handle.reader(init.io, &readbuf);
    // var writebuf = [_]u8{0} ** 1024;
    // var wdirs_writer = wdirs_handle.writer(init.io, &writebuf);

    var out_wdirs = wdirs_reader.interface;
    // var in_wdirs = wdirs_writer.interface;

    var watches = try wtree.Paths.init(init.gpa, init.io, mem.span(home));

    // Add watch for the watched_dirs itself
    // Doesn't require to be put in watches
    const manifest_wd: i32 = @intCast(std.os.linux.inotify_add_watch(watches.ifd, @ptrCast(wdirs_path),
        std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
        std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.MOVED_TO));

    try addExplicitDirs(init, &watches, &out_wdirs);
    try addTrackedFiles(init, &watches, repo);

    var fds = [_]std.os.linux.pollfd{
        .{ .fd = watches.ifd, .events = std.os.linux.POLL.IN, .revents = 0 },
        .{ .fd = pipe_read_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
    };

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
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

                try handleEvent(init, event, manifest_wd, &watches);

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
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) return error.GitError;
    defer c.git_index_free(index);

    // Read latest index from disk
    _ = c.git_index_read(index, 1);

    var i: usize = 0;
    const count = c.git_index_entrycount(index);
    while (i < count) : (i += 1) {
        const index_entry = c.git_index_get_byindex(index, i);
        const entry = try init.gpa.dupe(u8, std.mem.span(index_entry.*.path));

        try watches.add(init.gpa, init.io, entry, null);
    }
}

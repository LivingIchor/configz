const std = @import("std");
const mem = std.mem;
const c = @import("c.zig").git2;
const config = @import("config.zig");
const wtree = @import("watch-tree.zig");

// Fixed-size command sent over the pipe from the main thread to the watcher.
// Uses a flat buffer rather than a slice so it's safe to write/read atomically
// across the pipe without extra framing.
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

// Respond to a single inotify event. Dispatches on the event mask to either
// update or remove the affected file from the index.
fn handleEvent(
    init: std.process.Init,
    repo: *c.git_repository,
    watches: *wtree.Paths,
    home: []const u8,
    event: *std.os.linux.inotify_event,
) !void {
    std.log.debug("handleEvent: wd={d} mask={x}", .{event.wd, event.mask});

    const node = watches.hashes.wd_node.get(event.wd) orelse return;
    const name = event.getName() orelse return;
    std.log.debug("handleEvent: name='{s}' wd={d}", .{name, event.wd});

    // For file-granular watches, ignore events for files not in the set.
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

    // libgit2 requires null-terminated paths.
    const full_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{node.abs_dirname, name}, 0);
    defer init.gpa.free(full_path);

    if (event.mask & (std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO) != 0) {
        std.log.debug("handleEvent: modified {s}", .{full_path});

        var index: ?*c.git_index = null;
        if (c.git_repository_index(&index, repo) != 0) return error.GitError;
        defer c.git_index_free(index);
        if (c.git_index_read(index, 1) != 0) return error.GitError;

        // For whole-directory watches, only update files already tracked in the
        // index — we don't want to auto-stage every new file dropped in a watched dir.
        if (node.watch_data.file_set == null) {
            const rel_path_check = full_path[home.len + 1 .. full_path.len];
            const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path_check, 0);
            defer init.gpa.free(rel_path_z);
            if (c.git_index_get_bypath(index, rel_path_z, 0) == null) return;
        }

        const rel_path = full_path[home.len + 1 .. full_path.len];
        const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(rel_path_z);

        var oid: c.git_oid = undefined;
        if (c.git_blob_create_from_disk(&oid, repo, full_path) != 0)
            return error.GitError;

        // Stat before building the index entry so git status can detect future
        // changes by mtime/size comparison without re-hashing.
        var statx_buf: std.os.linux.Statx = undefined;
        const statx_rc = std.os.linux.statx(
            std.os.linux.AT.FDCWD, full_path, 0, .BASIC_STATS, &statx_buf);
        if (statx_rc != 0) return error.StatError;

        var entry: c.git_index_entry = std.mem.zeroes(c.git_index_entry);
        entry.path = rel_path_z;
        entry.id = oid;
        entry.mode = @intCast(statx_buf.mode);
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

        const rel_path = full_path[home.len + 1 .. full_path.len];
        const rel_path_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(rel_path_z);

        if (c.git_index_remove_bypath(index, rel_path_z) != 0) return error.GitError;
        if (c.git_index_write(index) != 0) return error.GitError;
    }
}

// Handle an add/remove command from the main thread, then persist the updated
// watched-dirs list so it survives daemon restarts.
fn handleCmd(
    init: std.process.Init,
    cmd: WatchCmd,
    watches: *wtree.Paths,
    home: []const u8,
) !void {
    const abs_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{home, cmd.getPath()});
    defer init.gpa.free(abs_path);

    const watched_dirs = try std.fmt.allocPrint(
        init.gpa, config.bare_repo_path_fmt ++ "/watched_dirs", .{home});
    defer init.gpa.free(watched_dirs);

    if (cmd.op == .add) {
        std.log.debug("handleCmd: adding watch for {s}", .{abs_path});
        try watches.add(init.gpa, init.io, abs_path, null);
    } else {
        std.log.debug("handleCmd: removing watch for {s}", .{abs_path});
        try watches.remove(init.gpa, init.io, abs_path);
    }

    try watches.writeWatchedDirs(init.io, watched_dirs);
}

// Error-swallowing entry point for running watchFiles on a thread.
pub fn watchFilesWrapper(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) void {
    watchFiles(init, repo, pipe_read_fd) catch |err| {
        std.log.err("watchFiles failed: {}", .{err});
    };
}

// Main watcher loop. Initializes inotify watches for all explicitly tracked
// directories and index-tracked files, then polls for inotify events and
// pipe commands indefinitely. inotify events update the index in place;
// pipe commands add or remove watches at runtime.
pub fn watchFiles(init: std.process.Init, repo: *c.git_repository, pipe_read_fd: i32) !void {
    std.log.info("watchFiles: starting", .{});
    const home = mem.span(std.c.getenv("HOME") orelse return error.MissingHome);

    const repo_path = c.git_repository_path(repo);
    std.log.info("watchFiles: repo path = {s}", .{std.mem.span(repo_path)});

    // watched_dirs persists the set of explicitly watched directories across
    // daemon restarts so we can re-register inotify watches on startup.
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

    try addTrackedFiles(init, &watches, repo, home);
    std.log.info("watchFiles: tracked files added", .{});

    var fds = [_]std.os.linux.pollfd{
        .{ .fd = watches.ifd, .events = std.os.linux.POLL.IN, .revents = 0 },
        .{ .fd = pipe_read_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
    };

    // inotify events are packed structs of variable length — the buffer must
    // be aligned to the event struct or the @ptrCast below is UB.
    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    std.log.info("watchFiles: entering poll loop", .{});

    while (true) {
        const poll_rc = std.os.linux.poll(&fds, fds.len, -1);
        if (poll_rc == std.math.maxInt(usize)) continue; // EINTR or transient error

        if (fds[0].revents & std.os.linux.POLL.IN != 0) {
            const len = std.os.linux.read(watches.ifd, &buf, buf.len);
            if (len == 0 or len == std.math.maxInt(usize)) continue;

            var offset: usize = 0;
            while (offset < len) {
                const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
                handleEvent(init, repo, &watches, home, event) catch |err| {
                    std.log.err("handleEvent failed: {}", .{err});
                };
                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }

        if (fds[1].revents & std.os.linux.POLL.IN != 0) {
            // Drain all pending commands — pipe is non-blocking so we loop
            // until read returns 0 (closed) or EAGAIN (no more data).
            while (true) {
                var cmd: WatchCmd = undefined;
                const n = std.os.linux.read(pipe_read_fd, @ptrCast(&cmd), @sizeOf(WatchCmd));
                if (n == 0 or n == std.math.maxInt(usize)) break;
                try handleCmd(init, cmd, &watches, home);
            }
        }
    }
}

// Re-register inotify watches for explicitly watched directories persisted
// from a previous daemon run.
fn addExplicitDirs(
    init: std.process.Init,
    watches: *wtree.Paths,
    manifest_reader: *std.Io.Reader,
) !void {
    while (manifest_reader.takeSentinel('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    }) |dir| {
        // watches.add dupes the path internally, no need to dupe here.
        try watches.add(init.gpa, init.io, dir, null);
    }
}

// Register inotify watches for every file currently tracked in the index so
// in-place edits to tracked files are picked up without an explicit `add`.
fn addTrackedFiles(
    init: std.process.Init,
    watches: *wtree.Paths,
    repo: *c.git_repository,
    home: []const u8,
) !void {
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) return error.GitError;
    defer c.git_index_free(index);
    if (c.git_index_read(index, 1) != 0) return error.GitError;

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

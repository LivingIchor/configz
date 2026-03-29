const std = @import("std");
const mem = std.mem;

const c = @import("c.zig").git2;
const clap = @import("clap");
const config = @import("config.zig");
const cmds = @import("commands.zig");
const auto = @import("auto.zig");


// ── Socket Data ──────────────────────────────────────────────────────────────────────────────────

pub const Response = union(enum) {
    ok: cmds.Packet(cmds.OkPayload),
    err: cmds.Packet(cmds.ErrPayload),
};

pub fn parsePacket(
    init: std.process.Init,
    repo: *?*c.git_repository,
    pipe_fds: [2]i32,
    streamin: *std.Io.Reader,
    streamout: *std.Io.Writer,
) !Response {
    const json_str = try streamin.takeDelimiter('\n') orelse return error.NoJSON;
    const json = std.mem.trimEnd(u8, json_str, "\n");
    std.log.debug("Received len={d}: '{s}'", .{json.len, json});
    if (json.len == 0) return error.NoJSON;

    const tag_only = std.json.parseFromSlice(
        cmds.TagOnly, init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
        std.log.err("malformed packet: {}", .{err});
        const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
        return Response{ .err = outgoing };
    };
    defer tag_only.deinit();

    if (repo.* == null and tag_only.value.tag != .init) {
        const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "repo not initialized, run 'configz init <remote>' first");
        return Response{ .err = outgoing };
    }

    var msg: []const u8 = "";
    switch (tag_only.value.tag) {
        .ping => {
            const pong = cmds.Packet(cmds.PongPayload).init(cmds.PongPayload{});
            try std.json.Stringify.value(pong, .{}, streamout);
            try streamout.writeByte('\n');
            try streamout.flush();

            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok =  outgoing };
        },
        .status => {
            const incoming = std.json.parseFromSlice(
                cmds.Packet(cmds.StatusPayload), init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
                std.log.err("malformed packet: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
                return Response{ .err =  outgoing };
            };
            defer incoming.deinit();

            cmds.handleStatus(init, repo.*, &msg) catch |err| {
                std.log.info("handleStatus error: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, msg);
                return Response{ .err = outgoing };
            };

            std.log.info("handleStatus success", .{});
            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok = outgoing };
        },
        .init => {
            if (repo.* != null) {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "repo already initialized");
                return Response{ .err = outgoing };
            }
            const incoming = std.json.parseFromSlice(
                cmds.Packet(cmds.InitPayload), init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
                std.log.err("malformed packet: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
                return Response{ .err =  outgoing };
            };
            defer incoming.deinit();

            if (incoming.value.payload.remote.len == 0) {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "init requires a remote URL");
                return Response{ .err = outgoing };
            }

            cmds.handleInit(init, repo, incoming.value.payload.remote, &msg) catch {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, msg);
                return Response{ .err = outgoing };
            };

            const thread = try std.Thread.spawn(.{},
                auto.watchFilesWrapper, .{init, repo.*.?, pipe_fds[0]});
            thread.detach();

            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok = outgoing };
        },
        .add => {
            const incoming = std.json.parseFromSlice(
                cmds.Packet(cmds.AddPayload), init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
                std.log.err("malformed packet: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
                return Response{ .err = outgoing };
            };
            defer incoming.deinit();

            if (incoming.value.payload.paths.len < 1) {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "add requires at least one file");
                return Response{ .err = outgoing };
            }

            // Construct list of potential additions
            var added_paths = try std.ArrayList([]const u8)
                .initCapacity(init.gpa, incoming.value.payload.paths.len);
            try added_paths.appendSlice(init.gpa, incoming.value.payload.paths);
            defer added_paths.deinit(init.gpa);
            defer for (added_paths.items) |item| {
                init.gpa.free(item);
            };

            // Attempts to add the list of files and sets the list of
            // added files to actual added files
            cmds.handleAdd(init, repo.*, &added_paths, &msg) catch {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, msg);
                return Response{ .err = outgoing };
            };

            for (added_paths.items) |file| {
                const cmd = auto.WatchCmd.init(.add, file);
                _ = std.os.linux.write(pipe_fds[1], @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
            }

            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok = outgoing };
        },
        .drop => {
            const incoming = std.json.parseFromSlice(
                cmds.Packet(cmds.DropPayload), init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
                std.log.err("malformed packet: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
                return Response{ .err = outgoing };
            };
            defer incoming.deinit();

            if (incoming.value.payload.paths.len < 1) {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "drop requires at least one file");
                return Response{ .err = outgoing };
            }

            // Construct list of potential drops
            var dropped_paths = try std.ArrayList([]const u8)
                .initCapacity(init.gpa, incoming.value.payload.paths.len);
            try dropped_paths.appendSlice(init.gpa, incoming.value.payload.paths);
            defer dropped_paths.deinit(init.gpa);
            defer for (dropped_paths.items) |item| {
                init.gpa.free(item);
            };

            // Attempts to drop the list of files and sets the list of
            // dropped files to actual dropped files
            cmds.handleDrop(init, repo.*, &dropped_paths, &msg) catch {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, msg);
                return Response{ .err = outgoing };
            };

            for (dropped_paths.items) |file| {
                const cmd = auto.WatchCmd.init(.remove, file);
                _ = std.os.linux.write(pipe_fds[1], @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
            }

            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok = outgoing };
        },
        .sync => {
            const incoming = std.json.parseFromSlice(
                cmds.Packet(cmds.SyncPayload), init.gpa, json, .{.ignore_unknown_fields = true}) catch |err| {
                std.log.err("malformed packet: {}", .{err});
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
                return Response{ .err = outgoing };
            };
            defer incoming.deinit();

            cmds.handleSync(
                init,
                repo.*,
                incoming.value.payload.subject,
                incoming.value.payload.body,
                streamin,
                streamout,
                &msg
            ) catch {
                const outgoing = cmds.Packet(cmds.ErrPayload).initMsg(.err, msg);
                return Response{ .err = outgoing };
            };

            const outgoing = cmds.Packet(cmds.OkPayload).initMsg(.ok, msg);
            return Response{ .ok = outgoing };
        },
        .pong, .ok, .err, .need_credentials, .credentials => {
            // These packet types are illegitimate server packets — they'll be
            // treated as bad packets
            const packet = cmds.Packet(cmds.ErrPayload).initMsg(.err, "Malformed Request");
            return Response{ .err = packet };
        },
    }
}


// ── Setup ────────────────────────────────────────────────────────────────────────────────────────

// An explicit signal handler
fn signalHandler(_: std.os.linux.SIG) callconv(.c) void {
    std.process.exit(0);
}

pub fn main(init: std.process.Init) !void {
    // Call handler when INT or TERM is received
    var sa = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &sa, null);

    const home = mem.span(std.c.getenv("HOME").?);

    // Get buffered stderr interface
    const errbuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(errbuf);
    var stderr_writer = std.Io.File.writer(.stderr(), init.io, errbuf);
    var stderr = &stderr_writer.interface;


    // ── Command line parsing ─────────────────────────────────────────────────────────────────────

    const params = comptime clap.parseParamsComptime(
        \\-h, --help        Show this help message
        \\-d, --daemon      Run as a separate daemon (for running outside systemd)
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    // Print a user friendly help message
    if (res.args.help != 0) {
        try stderr.writeAll("Usage: configzd ");
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeAll("\n\nOptions:\n");
        try clap.help(stderr, clap.Help, &params, .{});
        try stderr.writeAll("\n");
        try stderr.flush();
        return;
    }

    if (res.args.daemon != 0)
        try daemonize(init);


    // ── Git Setup ────────────────────────────────────────────────────────────────────────────────

    // Create pipe to communicate to the watch thread
    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);

    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    var repo: ?*c.git_repository = null;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    // Start watching the contents of any preexisting repo
    if (c.git_repository_open(&repo, repo_path) == 0) {
        const thread = try std.Thread.spawn(.{}, auto.watchFilesWrapper, .{init, repo.?, pipe_fds[0]});

        thread.detach();
    }
    defer if (repo) |r| c.git_repository_free(r);


    // ── Socket Setup ─────────────────────────────────────────────────────────────────────────────

    const runtime = init.minimal.environ.getAlloc(init.gpa, "XDG_RUNTIME_DIR") catch |err| {
        if (err == error.EnvironmentVariableMissing) {
            std.log.err("XDG_RUNTIME_DIR is not set", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer init.gpa.free(runtime);
    const socket_path = try std.fmt.allocPrint(init.gpa, config.socket_path_fmt, .{runtime});
    defer init.gpa.free(socket_path);

    // Remove stale socket if it exists
    std.Io.Dir.deleteFileAbsolute(init.io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {}, // fine, doesn't exist
        else => return err,
    };

    // Create the socket and the server interface
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(init.io, .{});
    defer server.deinit(init.io);


    // ── Main Socket Loop ─────────────────────────────────────────────────────────────────────────

    const sreadbuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(sreadbuf);
    const swritebuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(swritebuf);
    while (true) {
        // Block till a connection to the socket
        const connection = try server.accept(init.io);
        defer connection.close(init.io);

        var stream_reader = connection.reader(init.io, sreadbuf);
        const streamin = &stream_reader.interface;
        var stream_writer = connection.writer(init.io, swritebuf);
        const streamout = &stream_writer.interface;

        const response = parsePacket(
            init, &repo, pipe_fds, streamin, streamout) catch |err| {
            std.log.err("parsePacket failed: {}", .{err});
            continue;
        };
        writeResponse(streamout, response);
    }
}


// ── Helpers ──────────────────────────────────────────────────────────────────────────────────────

// Write a JSON response and flush. Broken-pipe errors (client disconnected
// before we could reply) are logged and swallowed
fn writeResponse(writer: *std.Io.Writer, response: Response) void {
    writeResponseInner(writer, response) catch |err| {
        std.log.debug("client write failed (client likely disconnected): {}", .{err});
    };
}

fn writeResponseInner(writer: *std.Io.Writer, response: Response) !void {
    switch (response) {
        .ok => |payload| try std.json.Stringify.value(payload, .{}, writer),
        .err => |payload| try std.json.Stringify.value(payload, .{}, writer),
    }
    try writer.writeByte('\n');
    try writer.flush();
}

fn daemonize(init: std.process.Init) !void {
    // First fork
    const pid1 = std.os.linux.fork();
    if (pid1 != 0) std.process.exit(0); // parent exits

    // New session
    _ = std.os.linux.setsid();

    // Second fork
    const pid2 = std.os.linux.fork();
    if (pid2 != 0) std.process.exit(0); // first child exits

    // Redirect stdin/stdout/stderr to /dev/null
    const devnull = try std.Io.Dir.openFileAbsolute(init.io, "/dev/null", .{ .mode = .read_write });
    _ = std.os.linux.dup2(devnull.handle, std.posix.STDIN_FILENO);
    _ = std.os.linux.dup2(devnull.handle, std.posix.STDOUT_FILENO);
    _ = std.os.linux.dup2(devnull.handle, std.posix.STDERR_FILENO);
    devnull.close(init.io);

    // Change working directory
    _ = std.os.linux.chdir("/");
}


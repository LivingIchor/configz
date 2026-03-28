const std = @import("std");
const mem = std.mem;

const c = @import("c.zig").git2;
const clap = @import("clap");
const config = @import("config.zig");
const cmds = @import("commands.zig");
const auto = @import("auto.zig");


// ── Socket Data ──────────────────────────────────────────────────────────────────────────────────

const Command = enum {
    status,
    sync,
    init,
    add,
    drop,
};

const Request = struct {
    cmd: Command,
    args: [][]const u8,
};

const Response = struct {
    ok: bool,
    output: []const u8,
};


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
    const pipe_read_fd = pipe_fds[0];
    const pipe_write_fd = pipe_fds[1];

    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    var repo: ?*c.git_repository = null;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    // Start watching the contents of any preexisting repo
    if (c.git_repository_open(&repo, repo_path) == 0) {
        const thread = try std.Thread.spawn(.{}, auto.watchFilesWrapper, .{init, repo.?, pipe_read_fd});

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
        var streamin = &stream_reader.interface;
        var stream_writer = connection.writer(init.io, swritebuf);
        const streamout = &stream_writer.interface;

        const json_str = try streamin.takeDelimiter('\n') orelse continue;
        const json_trimmed = std.mem.trimEnd(u8, json_str, "\n");
        std.log.debug("Received len={d}: '{s}'", .{json_trimmed.len, json_trimmed});
        if (json_trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(Request, init.gpa, json_trimmed, .{}) catch {
            sendError(streamout, "malformed request");
            continue;
        };
        defer parsed.deinit();

        if (repo == null and parsed.value.cmd != .init) {
            sendError(streamout, "repo not initialized, run 'configz init <remote>' first");
            continue;
        }


        // ── Cmd Dispatcher ───────────────────────────────────────────────────────────────────────

        var msg: []const u8 = "";
        defer if (msg.len > 0) init.gpa.free(msg);
        switch (parsed.value.cmd) {
            .status => {
                if (parsed.value.args.len > 0) {
                    sendError(streamout, "status doesn't take arguments");
                    continue;
                }

                cmds.handleStatus(init, repo, &msg) catch {
                    sendError(streamout, msg);
                    continue;
                };

                sendSuccess(streamout, msg);
            },
            .sync => {
                if (parsed.value.args.len < 1) {
                    sendError(streamout, "sync doesn't requires a subject");
                    continue;
                } else if (parsed.value.args.len > 2) {
                    sendError(streamout, "sync can only take a subject and body text");
                    continue;
                }

                // Set the commit message's subject and body
                const subject = try init.gpa.dupeSentinel(u8, parsed.value.args[0], 0);
                defer init.gpa.free(subject);
                const body = if (parsed.value.args.len == 2)
                    try init.gpa.dupeSentinel(u8, parsed.value.args[1], 0)
                else null;
                defer if (body) |b| init.gpa.free(b);

                cmds.handleSync(init, repo, subject, body, &msg) catch {
                    sendError(streamout, msg);
                    continue;
                };

                sendSuccess(streamout, msg);
            },
            .init => {
                if (repo != null) {
                    sendError(streamout, "repo already initialized");
                    continue;
                }

                if (parsed.value.args.len != 1) {
                    sendError(streamout, "init requires a remote URL");
                    continue;
                }

                const remote = try init.gpa.dupeSentinel(u8, parsed.value.args[0], 0);
                defer init.gpa.free(remote);

                cmds.handleInit(init, &repo, remote, &msg) catch {
                    sendError(streamout, msg);
                    continue;
                };

                sendSuccess(streamout, msg);

                const thread = try std.Thread.spawn(.{},
                    auto.watchFilesWrapper, .{init, repo.?, pipe_read_fd});
                thread.detach();
            },
            .add => {
                if (parsed.value.args.len < 1) {
                    sendError(streamout, "add requires at least one file");
                    continue;
                }

                // Construct list of potential additions
                var added_paths = try std.ArrayList([]const u8)
                    .initCapacity(init.gpa, parsed.value.args.len);
                try added_paths.appendSlice(init.gpa, parsed.value.args);
                defer added_paths.deinit(init.gpa);
                defer for (added_paths.items) |item| {
                    init.gpa.free(item);
                };

                // Attempts to add the list of files and sets the list of
                // added files to actual added files
                cmds.handleAdd(init, repo, &added_paths, &msg) catch {
                    sendError(streamout, msg);
                    continue;
                };

                for (added_paths.items) |file| {
                    const cmd = auto.WatchCmd.init(.add, file);
                    _ = std.os.linux.write(pipe_write_fd, @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
                }

                sendSuccess(streamout, msg);
            },
            .drop => {
                if (parsed.value.args.len < 1) {
                    sendError(streamout, "drop requires at least one file");
                    continue;
                }

                // Construct list of potential drops
                var dropped_paths = try std.ArrayList([]const u8)
                    .initCapacity(init.gpa, parsed.value.args.len);
                try dropped_paths.appendSlice(init.gpa, parsed.value.args);
                defer dropped_paths.deinit(init.gpa);
                defer for (dropped_paths.items) |item| {
                    init.gpa.free(item);
                };

                // Attempts to drop the list of files and sets the list of
                // dropped files to actual dropped files
                cmds.handleDrop(init, repo, &dropped_paths, &msg) catch {
                    sendError(streamout, msg);
                    continue;
                };

                for (dropped_paths.items) |file| {
                    const cmd = auto.WatchCmd.init(.remove, file);
                    _ = std.os.linux.write(pipe_write_fd, @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
                }

                sendSuccess(streamout, msg);
            },
        }
    }
}


// ── Helpers ──────────────────────────────────────────────────────────────────────────────────────

// Write a JSON response and flush. Broken-pipe errors (client disconnected
// before we could reply) are logged and swallowed
fn writeResponse(writer: *std.Io.Writer, value: Response) void {
    writeResponseInner(writer, value) catch |err| {
        std.log.debug("client write failed (client likely disconnected): {}", .{err});
    };
}

fn writeResponseInner(writer: *std.Io.Writer, value: Response) !void {
    var stringify = std.json.Stringify{.writer = writer};
    try stringify.write(value);
    try writer.writeByte('\n');
    try writer.flush();
}

// Simple functions for readability
fn sendSuccess(writer: *std.Io.Writer, msg: []const u8) void {
    writeResponse(writer, .{ .ok = true, .output = msg });
}
fn sendError(writer: *std.Io.Writer, msg: []const u8) void {
    writeResponse(writer, .{ .ok = false, .output = msg });
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


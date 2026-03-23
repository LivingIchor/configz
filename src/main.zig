const std = @import("std");
const c = @import("c.zig").git2;
const clap = @import("clap");
const config = @import("config.zig");
const cmds = @import("commands.zig");
const auto = @import("auto.zig");

const Command = enum {
    status,
    sync,
    init,
    git,
    add,
    drop,
};


const Request = struct {
    cmd: Command,
    args: []const []const u8,
};

fn signalHandler(_: std.os.linux.SIG) callconv(.c) void {
    std.process.exit(0);
}

pub fn main(init: std.process.Init) !void {
    var sa = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &sa, null);

    var argv = std.process.Args.iterate(init.minimal.args);
    const procname = argv.next().?;
    const errbuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(errbuf);
    var stderr_writer = std.Io.File.writer(.stderr(), init.io, errbuf);
    var stderr = &stderr_writer.interface;

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

    if (res.args.help != 0) {
        try stderr.print("Usage: {s} ", .{std.fs.path.basename(procname)});
        try clap.usage(stderr, clap.Help, &params);
        try stderr.print("\n\nOptions:\n", .{});
        try clap.help(stderr, clap.Help, &params, .{});
        try stderr.print("\n", .{});
        try stderr.flush();
        return;
    }

    if (res.args.daemon != 0)
        try daemonize(init);

    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

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
    const address = try std.Io.net.UnixAddress.init(socket_path);

    const home = std.c.getenv("HOME").?;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    var no_repo = false;
    var repo: ?*c.git_repository = null;
    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    const pipe_read_fd = pipe_fds[0];
    const pipe_write_fd = pipe_fds[1];
    if (c.git_repository_open(&repo, repo_path) != 0) {
        no_repo = true;
    } else {
        const thread = try std.Thread.spawn(.{}, auto.watchFilesWrapper, .{init, repo.?, pipe_read_fd});

        thread.detach();
    }
    defer if (repo) |r| c.git_repository_free(r);

    // Remove stale socket if it exists
    std.Io.Dir.deleteFileAbsolute(init.io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {}, // fine, doesn't exist
        else => return err,
    };
    var server = try address.listen(init.io, .{});
    defer server.deinit(init.io);

    const sreadbuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(sreadbuf);
    const swritebuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(swritebuf);
    while (true) {
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
            try sendError(streamout, "malformed request");
            continue;
        };
        defer parsed.deinit();

        if (no_repo and parsed.value.cmd != .init) {
            try sendError(streamout, "repo not initialized, run 'configz init <remote>' first");
            continue;
        }

        var err_msg: []const u8 = "";
        switch (parsed.value.cmd) {
            .status => {
                if (parsed.value.args.len > 0) {
                    try sendError(streamout, "status doesn't take arguments");
                    continue;
                }

                cmds.handleStatus(init, repo, &err_msg) catch {
                    try sendError(streamout, err_msg);
                    continue;
                };

                var stringify = std.json.Stringify{.writer = streamout};
                try stringify.write(.{ .ok = true, .output = err_msg });
                try streamout.writeByte('\n');
                try streamout.flush();
            },
            .sync => {
                if (parsed.value.args.len < 1) {
                    try sendError(streamout, "sync doesn't requires a subject");
                    continue;
                } else if (parsed.value.args.len > 2) {
                    try sendError(streamout, "sync can only take a subject and body text");
                    continue;
                }

                const subject = try init.gpa.dupeSentinel(u8, parsed.value.args[0], 0);
                defer init.gpa.free(subject);
                const body = if (parsed.value.args.len == 2)
                    try init.gpa.dupeSentinel(u8, parsed.value.args[1], 0)
                else null;
                defer if (body) |b| init.gpa.free(b);

                cmds.handleSync(init, repo, subject, body, &err_msg) catch {
                    try sendError(streamout, err_msg);
                    continue;
                };

                try sendSuccess(streamout);
            },
            .init => {
                if (!no_repo) {
                    try sendError(streamout, "repo already initialized");
                    continue;
                }

                if (parsed.value.args.len != 1) {
                    try sendError(streamout, "init requires one remote URL");
                    continue;
                }

                const remote = try init.gpa.dupeSentinel(u8, parsed.value.args[0], 0);
                defer init.gpa.free(remote);

                cmds.handleInit(init, &repo, remote, &err_msg) catch {
                    const msg: []const u8 = err_msg;
                    try sendError(streamout, msg);
                    continue;
                };

                no_repo = false;

                try sendSuccess(streamout);

                const thread = try std.Thread.spawn(.{},
                    auto.watchFilesWrapper, .{init, repo.?, pipe_read_fd});
                thread.detach();
            },
            .git => {
                if (parsed.value.args.len < 1) {
                    try sendError(streamout, "git requires at least one argument");
                    continue;
                }

                var out: []const u8 = "";
                var err: []const u8 = "";
                try cmds.handleGit(init, parsed.value.args, &out, &err);

                var stringify = std.json.Stringify{.writer = streamout};
                try stringify.write(.{ .ok = true, .output = .{
                    .out = @as([]const u8, out),
                    .err = @as([]const u8, err),
                }});
                try streamout.writeByte('\n');
                try streamout.flush();
            },
            .add => {
                if (parsed.value.args.len < 1) {
                    try sendError(streamout, "add requires at least one file");
                    continue;
                }

                var added_paths = try std.ArrayList([]const u8)
                    .initCapacity(init.gpa, parsed.value.args.len);
                defer added_paths.deinit(init.gpa);

                cmds.handleAdd(init, repo, parsed.value.args, &err_msg, &added_paths) catch {
                    const msg: []const u8 = err_msg;
                    try sendError(streamout, msg);
                    continue;
                };

                for (added_paths.items) |file| {
                    const cmd = auto.WatchCmd.init(.add, file);
                    _ = std.os.linux.write(pipe_write_fd, @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
                }

                try sendSuccess(streamout);
            },
            .drop => {
                if (parsed.value.args.len < 1) {
                    try sendError(streamout, "drop requires at least one file");
                    continue;
                }

                var dropped_paths = try std.ArrayList([]const u8)
                    .initCapacity(init.gpa, parsed.value.args.len);
                defer dropped_paths.deinit(init.gpa);

                cmds.handleDrop(init, repo, parsed.value.args, &err_msg, &dropped_paths) catch {
                    const msg: []const u8 = err_msg;
                    try sendError(streamout, msg);
                    continue;
                };

                for (dropped_paths.items) |file| {
                    const cmd = auto.WatchCmd.init(.remove, file);
                    _ = std.os.linux.write(pipe_write_fd, @ptrCast(&cmd), @sizeOf(auto.WatchCmd));
                }

                try sendSuccess(streamout);
            },
        }
    }
}

fn sendSuccess(writer: *std.Io.Writer) !void {
    var stringify = std.json.Stringify{.writer = writer};
    try stringify.write(.{ .ok = true, .output = "" });
    try writer.writeByte('\n');
    try writer.flush();
}

fn sendError(writer: *std.Io.Writer, msg: []const u8) !void {
    var stringify = std.json.Stringify{.writer = writer};
    try stringify.write(.{ .ok = false, .output = msg });
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


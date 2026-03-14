const std = @import("std");
const clap = @import("clap");
const config = @import("config.zig");
const cmds = @import("commands.zig");

const Command = enum {
    status,
    log,
    sync,
    pull,
    fetch,
    init,
    git,
    diff,
    add,
    drop,
};

const Request = struct {
    cmd: Command,
    args: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
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

    const runtime = init.minimal.environ.getAlloc(init.gpa, "XDG_RUNTIME_DIR") catch |err| {
        if (err == error.EnvironmentVariableMissing) {
            std.log.err("XDG_RUNTIME_DIR is not set", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer init.gpa.free(runtime);
    const socket_path = try std.fmt.allocPrint(init.gpa, config.socket_path_fmt, runtime);
    defer init.gpa.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen();
    defer server.deinit();

    const sreadbuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(sreadbuf);
    const swritebuf = try init.gpa.alloc(u8, 1024);
    defer init.gpa.free(swritebuf);
    while (true) {
        const connection = try server.accept();
        defer connection.close();

        var stream_reader = connection.reader(init.io, sreadbuf);
        var streamin = &stream_reader.interface;
        var stream_writer = connection.writer(init.io, swritebuf);
        const streamout = &stream_writer.interface;

        const json_str = streamin.takeDelimiter('\n');
        const cmd_json = try std.json.parseFromSlice(std.json.Value, init.gpa, json_str, .{});
        defer cmd_json.deinit();

        const parsed = try std.json.parseFromSlice(Request, init.gpa, json_str, .{});
        defer parsed.deinit();

        switch (parsed.value.cmd) {
            .status => {
                if (parsed.value.args.len > 0)
                    try sendError(streamout, "status doesn't take arguments");

                try cmds.handleStatus();
            },
            .log => {
                if (parsed.value.args.len > 0)
                    try sendError(streamout, "log doesn't take arguments");

                try cmds.handleLog();
            },
            .sync => {
                if (parsed.value.args.len < 1)
                    try sendError(streamout, "sync doesn't requires a subject")
                else if (parsed.value.args.len > 2)
                    try sendError(streamout, "sync can only take a subject and body text");

                const subject = parsed.value.args[0];
                const body = if (parsed.value.args.len == 2) parsed.value.args[1] else null;

                try cmds.handleSync(subject, body);
            },
            .pull => {
                if (parsed.value.args.len > 0)
                    try sendError(streamout, "pull doesn't take arguments");

                try cmds.handlePull();
            },
            .fetch => {
                if (parsed.value.args.len > 0)
                    try sendError(streamout, "fetch doesn't take arguments");

                try cmds.handleFetch();
            },
            .init => {
                if (parsed.value.args.len != 1)
                    try sendError(streamout, "init requires one remote URL");

                try cmds.handleInit(parsed.value.args[0]);
            },
            .git => {
                if (parsed.value.args.len < 1)
                    try sendError(streamout, "git requires at least one argument");

                try cmds.handleGit(parsed.value.args);
            },
            .diff => {
                if (parsed.value.args.len < 1)
                    try sendError(streamout, "diff requires at least one file");

                try cmds.handleDiff(parsed.value.args);
            },
            .add => {
                if (parsed.value.args.len < 1)
                    try sendError(streamout, "add requires at least one file");

                try cmds.handleAdd(parsed.value.args);
            },
            .drop => {
                if (parsed.value.args.len < 1)
                    try sendError(streamout, "drop requires at least one file");

                try cmds.handleDrop(parsed.value.args);
            },
        }
    }
}

fn sendError(writer: std.Io.Writer, msg: []const u8) !void {
    try std.json.stringify(.{ .ok = false, .output = msg }, .{}, writer);
    try writer.writeByte('\n');
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


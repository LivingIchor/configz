const std = @import("std");

const git = @cImport({
    @cInclude("git2.h");
});

fn handleStatus() !void {
}

fn handleLog() !void {
}

fn handleSync(subject: []const u8, body: ?[]const u8) !void {
}

fn handlePull() !void {
}

fn handleFetch() !void {
}

fn handleInit(remote: []const u8) !void {
}

fn handleGit(args: []const []const u8) !void {
}

fn handleDiff(args: []const []const u8) !void {
}

fn handleAdd(args: []const []const u8) !void {
}

fn handleDrop(args: []const []const u8) !void {
}


const std = @import("std");
const c = @import("c.zig").git2;
const config = @import("config.zig");

pub fn handleStatus(init: std.process.Init, repo: ?*c.git_repository, msg: *[]const u8) !void {
    var status_list: ?*c.git_status_list = null;
    var opts: c.git_status_options = undefined;
    _ = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    opts.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;

    if (c.git_status_list_new(&status_list, repo, &opts) != 0) {
        msg.* = try init.gpa.dupe(u8, "failed to get status");
        return error.GitError;
    }
    defer c.git_status_list_free(status_list);

    const count = c.git_status_list_entrycount(status_list);

    if (count == 0) {
        msg.* = try init.gpa.dupe(u8, "nothing to commit, working tree clean");
        return;
    }

    var i: usize = 0;
    var result: ?[]const u8 = null;
    while (i < count) : (i += 1) {
        const entry = c.git_status_byindex(status_list, i);
        const status = entry.*.status;
        const path = if (entry.*.index_to_workdir != null)
            entry.*.index_to_workdir.*.old_file.path
        else
            entry.*.head_to_index.*.old_file.path;

        var new_result: []const u8 = undefined;
        if ((status & c.GIT_STATUS_INDEX_NEW) != 0) {
            if (result) |res| {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "{s}A  {s}\n",
                    .{ res, path });
                init.gpa.free(res);
            } else {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "A  {s}\n",
                    .{ path });
            }
            result = new_result;
        }
        if ((status & c.GIT_STATUS_INDEX_MODIFIED) != 0) {
            if (result) |res| {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "{s}M  {s}\n",
                    .{ res, path });
                init.gpa.free(res);
            } else {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "M  {s}\n",
                    .{ path });
            }
            result = new_result;
        }
        if ((status & c.GIT_STATUS_INDEX_DELETED) != 0) {
            if (result) |res| {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "{s}D  {s}\n",
                    .{ res, path });
                init.gpa.free(res);
            } else {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "D  {s}\n",
                    .{ path });
            }
            result = new_result;
        }
        if ((status & c.GIT_STATUS_WT_MODIFIED) != 0) {
            if (result) |res| {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "{s} M {s}\n",
                    .{ res, path });
                init.gpa.free(res);
            } else {
                new_result = try std.fmt.allocPrint(
                    init.gpa, " M {s}\n",
                    .{ path });
            }
            result = new_result;
        }
        if ((status & c.GIT_STATUS_WT_DELETED) != 0) {
            if (result) |res| {
                new_result = try std.fmt.allocPrint(
                    init.gpa, "{s} D {s}\n",
                    .{ res, path });
                init.gpa.free(res);
            } else {
                new_result = try std.fmt.allocPrint(
                    init.gpa, " D {s}\n",
                    .{ path });
            }
            result = new_result;
        }
    }
    defer if (result) |res| init.gpa.free(res);

    msg.* = try init.gpa.dupe(u8, if (result) |res| res else "");
}

pub fn handleSync(
    init: std.process.Init,
    repo: ?*c.git_repository,
    subject: []const u8,
    body: ?[]const u8,
    err_msg: *[]const u8
) !void {
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    var tree_oid: c.git_oid = undefined;
    if (c.git_index_write_tree(&tree_oid, index) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to write tree");
        return error.GitError;
    }

    var tree: ?*c.git_tree = null;
    if (c.git_tree_lookup(&tree, repo, &tree_oid) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to lookup tree");
        return error.GitError;
    }
    defer c.git_tree_free(tree);

    const message = if (body) |b|
        try std.fmt.allocPrintSentinel(init.gpa, "{s}\n\n{s}\n", .{ subject, b }, 0)
    else
        try std.fmt.allocPrintSentinel(init.gpa, "{s}\n", .{subject}, 0);
    defer init.gpa.free(message);

    var sig: ?*c.git_signature = null;
    if (c.git_signature_default(&sig, repo) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to get git signature, is user.name and user.email set?");
        return error.GitError;
    }
    defer c.git_signature_free(sig);

    var parent: ?*c.git_commit = null;
    var head_ref: ?*c.git_reference = null;
    const has_head = c.git_repository_head(&head_ref, repo) == 0;
    if (has_head) {
        defer c.git_reference_free(head_ref);
        const head_oid: ?*const c.git_oid = c.git_reference_target(head_ref);
        _ = c.git_commit_lookup(&parent, repo, head_oid);
    }
    defer if (parent != null) c.git_commit_free(parent);

    var parents = [_]?*c.git_commit{parent};
    const parent_count: usize = if (has_head) 1 else 0;

    var commit_oid: c.git_oid = undefined;
    if (c.git_commit_create(
        &commit_oid,
        repo,
        "HEAD",
        sig,
        sig,
        null,
        message,
        tree,
        parent_count,
        if (parent_count > 0) @ptrCast(&parents) else null,
    ) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to create commit");
        return error.GitError;
    }

    // Push to origin
    var remote_obj: ?*c.git_remote = null;
    if (c.git_remote_lookup(&remote_obj, repo, "origin") != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to lookup remote");
        return error.GitError;
    }
    defer c.git_remote_free(remote_obj);

    const refspecs = [_][*:0]const u8{"refs/heads/master:refs/heads/master"};
    const refspec_array = c.git_strarray{
        .strings = @constCast(@ptrCast(&refspecs)),
        .count = 1,
    };

    if (c.git_remote_push(remote_obj, &refspec_array, null) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to push to remote");
        return error.GitError;
    }
}

pub fn handleInit(
    init: std.process.Init,
    repo: *?*c.git_repository,
    remote: []const u8,
    err_msg: *[]const u8
) !void {
    const remote_z = try init.gpa.dupeSentinel(u8, remote, 0);
    defer init.gpa.free(remote_z);

    const home = std.c.getenv("HOME").?;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    const init_err = c.git_repository_init(repo, repo_path, 1);
    if (init_err != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to create bare repo");
        return error.GitError;
    }

    _ = c.git_repository_set_workdir(repo.*, home, 0);

    var remote_obj: ?*c.git_remote = null;
    const remote_err = c.git_remote_create(&remote_obj, repo.*, "origin", remote_z);
    if (remote_err != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to create remote");
        return error.GitError;
    }
    defer c.git_remote_free(remote_obj);

    var cfg: ?*c.git_config = null;
    _ = c.git_repository_config(&cfg, repo.*);
    defer c.git_config_free(cfg);
    _ = c.git_config_set_bool(cfg, "core.bare", 0);
    _ = c.git_config_set_string(cfg, "core.worktree", home);
    _ = c.git_config_set_string(cfg, "status.showUntrackedFiles", "no");
}

pub fn handleAdd(
    init: std.process.Init,
    repo: ?*c.git_repository,
    args: []const []const u8,
    err_msg: *[]const u8,
    added_paths: *std.ArrayList([]const u8)
) !void {
    const home = std.c.getenv("HOME").?;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    // Get the index
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    // Add each file by path relative to HOME
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args) |file| {
        addPath(init, repo.?, index.?, home, file, &buf, &pos) catch continue;
        try added_paths.append(init.gpa, try init.gpa.dupe(u8, file));
    }
    if (pos > 0) {
        err_msg.* = try std.fmt.allocPrint(init.gpa, "Some files failed to add:{s}", .{buf[0..pos]});
        return error.GitError;
    }

    // Persist the index
    if (c.git_index_write(index) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to write index");
        return error.GitError;
    }
}

fn addPath(
    init: std.process.Init,
    repo: *c.git_repository,
    index: *c.git_index,
    home: [*:0]const u8,
    rel_path: []const u8,
    buf: []u8,
    pos: *usize
) !void {
    const full_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{ home, rel_path }, 0);
    defer init.gpa.free(full_path);

    const maybe_dir = std.Io.Dir.openDirAbsolute(init.io, full_path, .{.iterate = true});
    if (maybe_dir) |dir| {
        defer dir.close(init.io);
        var it = dir.iterate();
        while (try it.next(init.io)) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;

            const child_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ rel_path, entry.name });
            defer init.gpa.free(child_path);
            try addPath(init, repo, index, home, child_path, buf, pos);
        }
    } else |_| {
        const file_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(file_z);

        var oid: c.git_oid = undefined;
        if (c.git_blob_create_from_disk(&oid, repo, full_path) != 0) {
            pos.* += (try std.fmt.bufPrint(buf[pos.*..], "\n ~> {s}: failed to create blob", .{rel_path})).len;
            return error.GitError;
        }

        var statx_buf: std.os.linux.Statx = undefined;
        _ = std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            full_path,
            0,
            .BASIC_STATS,
            &statx_buf,
        );

        var entry: c.git_index_entry = std.mem.zeroes(c.git_index_entry);
        entry.path = file_z;
        entry.mode = 0o100644;
        entry.id = oid;
        entry.mode = statx_buf.mode;
        entry.file_size = @intCast(statx_buf.size);
        entry.mtime.seconds = @intCast(statx_buf.mtime.sec);
        entry.mtime.nanoseconds = @intCast(statx_buf.mtime.nsec);
        entry.ctime.seconds = @intCast(statx_buf.ctime.sec);
        entry.ctime.nanoseconds = @intCast(statx_buf.ctime.nsec);

        if (c.git_index_add(index, &entry) != 0) {
            pos.* += (try std.fmt.bufPrint(buf[pos.*..], "\n ~> {s}: failed to add", .{rel_path})).len;
            return error.GitError;
        }
    }
}

pub fn handleDrop(
    init: std.process.Init,
    repo: ?*c.git_repository,
    args: []const []const u8,
    err_msg: *[]const u8,
    dropped_paths: *std.ArrayList([]const u8)
) !void {
    const home = std.c.getenv("HOME").?;
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args) |file| {
        dropPath(init, index.?, home, file, &buf, &pos) catch continue;
        try dropped_paths.append(init.gpa, try init.gpa.dupe(u8, file));
    }
    if (pos > 0) {
        err_msg.* = try std.fmt.allocPrint(init.gpa, "Some files failed to be dropped:{s}", .{buf[0..pos]});
        return error.GitError;
    }

    if (c.git_index_write(index) != 0) {
        err_msg.* = try init.gpa.dupe(u8, "failed to write index");
        return error.GitError;
    }
}

fn dropPath(
    init: std.process.Init,
    index: *c.git_index,
    home: [*:0]const u8,
    rel_path: []const u8,
    buf: []u8,
    pos: *usize
) !void {
    const full_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{ home, rel_path }, 0);
    defer init.gpa.free(full_path);

    const maybe_dir = std.Io.Dir.openDirAbsolute(init.io, full_path, .{ .iterate = true });
    if (maybe_dir) |dir| {
        defer dir.close(init.io);
        var it = dir.iterate();
        while (try it.next(init.io)) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;
            const child_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ rel_path, entry.name });
            defer init.gpa.free(child_path);
            try dropPath(init, index, home, child_path, buf, pos);
        }
    } else |_| {
        const file_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
        defer init.gpa.free(file_z);

        std.log.debug("dropPath: removing '{s}' from index, result={d}",
            .{rel_path, c.git_index_remove(index, file_z, 0)});
        // if (c.git_index_remove(index, file_z, 0) != 0) {
        //     pos.* += (try std.fmt.bufPrint(buf[pos.*..], "\n ~> {s}: failed to remove", .{rel_path})).len;
        //     return error.GitError;
        // }
    }
}

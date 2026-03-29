const std = @import("std");
const mem = std.mem;

const c = @import("c.zig").git2;
const config = @import("config.zig");

extern fn strerror(errnum: c_int) [*:0]const u8;

pub const MsgTag = enum {
    // CLI → daemon
    ping,
    status,
    init,
    add,
    drop,
    sync,
    credentials,

    // daemon → CLI
    pong,
    ok,
    err,
    need_credentials,
};

pub fn Packet(comptime T: type) type {
    return struct {
        const Self = @This();

        tag: MsgTag,
        payload: T,

        pub fn init(payload: T) Self {
            const tag = switch (T) {
                PingPayload => MsgTag.ping,
                StatusPayload => MsgTag.status,
                InitPayload => MsgTag.init,
                AddPayload => MsgTag.add,
                DropPayload => MsgTag.drop,
                SyncPayload => MsgTag.sync,
                CredentialsPayload => MsgTag.credentials,

                PongPayload => MsgTag.pong,
                OkPayload => MsgTag.ok,
                ErrPayload => MsgTag.err,
                NeedCredentialsPayload => MsgTag.need_credentials,
                else => @compileError("unsupported payload type"),
            };

            return .{ .tag = tag, .payload = payload };
        }

        pub fn initMsg(comptime tag: MsgTag, message: []const u8) Self {
            switch (tag) {
                MsgTag.ok => {
                    if (T != OkPayload) @compileError("initMsg: tag must match payload type");
                    return Packet(T).init(T{ .message = message });
                },
                MsgTag.err => {
                    if (T != ErrPayload) @compileError("initMsg: tag must match payload type");
                    return Packet(T).init(T{ .message = message });
                },
                else => @compileError("initMsg only takes message type packets"),
            }
        }
    };
}

// Concrete payload types
pub const PingPayload = struct {};
pub const StatusPayload = struct {};
pub const InitPayload = struct { remote: []const u8 };
pub const AddPayload = struct { paths: [][]const u8 };
pub const DropPayload = struct { paths: [][]const u8 };
pub const SyncPayload = struct { subject: []const u8, body: []const u8 };
pub const CredentialsPayload = struct { username: []const u8, password: []const u8, };

pub const PongPayload = struct {};
pub const OkPayload = struct { message: []const u8 };
pub const ErrPayload = struct { message: []const u8 };
pub const NeedCredentialsPayload = struct { url: []const u8 };

// First pass: just get the tag
pub const TagOnly = struct { tag: MsgTag };


// ── Cmd Handlers ─────────────────────────────────────────────────────────────────────────────────

// Pretty print the status of the git repo
pub fn handleStatus(init: std.process.Init, repo: ?*c.git_repository, msg: *[]const u8) !void {
    std.debug.assert(repo != null);

    var opts: c.git_status_options = undefined;
    const init_rc = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    std.debug.assert(init_rc == 0);
    opts.show = c.GIT_STATUS_SHOW_INDEX_ONLY; // WT and Index should never deviate

    // Create list of index statuses
    var status_list: ?*c.git_status_list = null;
    const rc = c.git_status_list_new(&status_list, repo, &opts);
    if (rc != 0) {
        // Check if it's just an unborn branch (no commits yet)
        const err = c.git_error_last();
        if (err != null and err.*.klass == c.GIT_ERROR_REFERENCE) {
            // Repo is empty / HEAD is unborn — status is trivially clean or all staged
            return;
        }
        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_status_list_new: {s}\n", .{detail});
        msg.* = try init.gpa.dupe(u8, "failed to get status");

        return error.GitError;
    }
    defer c.git_status_list_free(status_list);

    // Check the number of index changes
    const count = c.git_status_list_entrycount(status_list);
    if (count == 0) { // No changes made to tracked files
        msg.* = try init.gpa.dupe(u8, "Nothing to sync");
        return;
    }

    msg.* = try init.gpa.dupe(u8, "Since last sync:\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = c.git_status_byindex(status_list, i);
        const status = entry.*.status;
        const path = if (entry.*.index_to_workdir != null)
            entry.*.index_to_workdir.*.old_file.path
        else
            entry.*.head_to_index.*.old_file.path;

        // INDEX_(NEW|MODIFIED|DELETED) are all mutually exclusive
        var action: []const u8 = undefined;
        if ((status & c.GIT_STATUS_INDEX_MODIFIED) != 0) {
            action = "Modified";
        } else if ((status & c.GIT_STATUS_INDEX_NEW) != 0) {
            action = "Added";
        } else if ((status & c.GIT_STATUS_INDEX_DELETED) != 0) {
            action = "Dropped";
        } else continue;

        // Add a line describing action on the ith entry
        const new_result = try std.fmt.allocPrint(
            init.gpa, "{s}  {s}\t{s}\n",
            .{ msg.*, action, path });
        init.gpa.free(msg.*);
        msg.* = new_result;
    }
}

// Stage → tree → commit → push. Every sync is immediately pushed to keep
// remotes current across machines — no local-only commits
pub fn handleSync(
    init: std.process.Init,
    repo: ?*c.git_repository,
    subject: []const u8,
    body: ?[]const u8,
    streamin: *std.Io.Reader,
    streamout: *std.Io.Writer,
    msg: *[]const u8
) !void {
    var index: ?*c.git_index = null;
    const index_rc = c.git_repository_index(&index, repo);
    if (index_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_repository_index: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    // persist index before writing tree
    _ = c.git_index_write(index);

    // Serialize the index into a tree object in the object store
    var tree_oid: c.git_oid = undefined;
    const write_rc = c.git_index_write_tree(&tree_oid, index);
    if (write_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_index_write_tree: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to write tree");
        return error.GitError;
    }

    // git_commit_create needs a *git_tree, not a bare OID
    var tree: ?*c.git_tree = null;
    const tree_lookup_rc = c.git_tree_lookup(&tree, repo, &tree_oid);
    if (tree_lookup_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_tree_lookup: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to lookup tree");
        return error.GitError;
    }
    defer c.git_tree_free(tree);

    // Set message as standard git subject/body format
    const message = if (body) |b|
        try std.fmt.allocPrintSentinel(init.gpa, "{s}\n\n{s}\n", .{ subject, b }, 0)
    else
        try std.fmt.allocPrintSentinel(init.gpa, "{s}\n", .{subject}, 0);
    defer init.gpa.free(message);

    // Reads user.name and user.email from repo config.
    var sig: ?*c.git_signature = null;
    if (c.git_signature_default(&sig, repo) != 0) {
        msg.* = try init.gpa.dupe(u8, "failed to get git signature, is user.name and user.email set?");
        return error.GitError;
    }
    defer c.git_signature_free(sig);

    // Root commit if no HEAD yet (first sync), otherwise chain off current HEAD.
    var parent: ?*c.git_commit = null;
    var head_ref: ?*c.git_reference = null;
    const has_head = c.git_repository_head(&head_ref, repo) == 0;
    if (has_head) {
        defer c.git_reference_free(head_ref);
        const head_oid: ?*const c.git_oid = c.git_reference_target(head_ref);
        if (c.git_commit_lookup(&parent, repo, head_oid) != 0) {
            msg.* = try init.gpa.dupe(u8, "failed to lookup parent commit");
            return error.GitError;
        }
    }
    defer if (parent != null) c.git_commit_free(parent);

    var parents = [_]?*c.git_commit{parent};
    const parent_count: usize = if (has_head) 1 else 0;

    var commit_oid: c.git_oid = undefined;
    const commit_rc = c.git_commit_create(
        &commit_oid,
        repo,
        "HEAD",
        sig,
        sig,
        null, // encoding: null defaults to UTF-8
        message,
        tree,
        parent_count,
        if (parent_count > 0) @ptrCast(&parents) else null,
    );
    if (commit_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_commit_create: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to create commit");
        return error.GitError;
    }

    // Look up fresh each time so URL changes in config are picked up.
    var remote_obj: ?*c.git_remote = null;
    const remote_lookup_rc = c.git_remote_lookup(&remote_obj, repo, "origin");
    if (remote_lookup_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_remote_lookup: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to lookup remote");
        return error.GitError;
    }
    defer c.git_remote_free(remote_obj);

    // Explicit refspec since tracking may not be configured on a fresh repo.
    const refspecs = [_][*:0]const u8{"refs/heads/main:refs/heads/main"};
    const refspec_array = c.git_strarray{
        .strings = @constCast(@ptrCast(&refspecs)),
        .count = 1,
    };

    var cred_payload = CredCallbackPayload{
        .io = init.io,
        .streamin = streamin,
        .streamout = streamout,
    };

    var callbacks: c.git_remote_callbacks = undefined;
    _ = c.git_remote_init_callbacks(&callbacks, c.GIT_REMOTE_CALLBACKS_VERSION);
    callbacks.credentials = credentialCallback;
    callbacks.payload = &cred_payload;

    var push_opts: c.git_push_options = undefined;
    _ = c.git_push_options_init(&push_opts, c.GIT_PUSH_OPTIONS_VERSION);
    push_opts.callbacks = callbacks;

    const push_rc = c.git_remote_push(remote_obj, &refspec_array, &push_opts);
    if (push_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_remote_push: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to push to remote");
        return error.GitError;
    }
}

const CredCallbackPayload = struct {
    io: std.Io,
    streamin: *std.Io.Reader,
    streamout: *std.Io.Writer,
    attempts: u8 = 0,
};

fn credentialCallback(
    out: [*c]?*c.git_credential,
    url: [*c]const u8,
    username_from_url: [*c]const u8,
    allowed_types: c_uint,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *CredCallbackPayload = @ptrCast(@alignCast(payload));
    ctx.attempts += 1;
    if (ctx.attempts > 3) return c.GIT_EAUTH;

    if (allowed_types & c.GIT_CREDENTIAL_SSH_KEY != 0) {
        const home = std.mem.span(std.c.getenv("HOME") orelse return c.GIT_EAUTH);
        const key_names = [_][]const u8{ "id_ed25519", "id_rsa", "id_ecdsa" };
        for (key_names) |name| {
            var pub_buf: [512]u8 = undefined;
            var priv_buf: [512]u8 = undefined;

            const pub_path = std.fmt.bufPrintZ(&pub_buf, "{s}/.ssh/{s}.pub", .{ home, name })
                catch continue;
            const priv_path = std.fmt.bufPrintZ(&priv_buf, "{s}/.ssh/{s}", .{ home, name })
                catch continue;

            _ = std.Io.Dir.openFileAbsolute(ctx.io, priv_path, .{}) catch continue;

            // Prompt CLI for passphrase — reuse need_credentials, password = passphrase
            var req_buf: [1024]u8 = undefined;
            const req = std.fmt.bufPrint(&req_buf,
                "{{\"tag\":\"need_credentials\",\"payload\":{{\"url\":\"{s}\"}}}}\n",
                .{priv_path}) catch return c.GIT_EAUTH;
            ctx.streamout.writeAll(req) catch return c.GIT_EAUTH;
            ctx.streamout.flush() catch return c.GIT_EAUTH;

            const resp_str = ctx.streamin.takeDelimiter('\n') catch return c.GIT_EAUTH;
            const resp = resp_str orelse return c.GIT_EAUTH;

            var fba_buf: [512]u8 = undefined;
            var passphrase_buf: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const parsed = std.json.parseFromSlice(
                struct { tag: []const u8, payload: CredentialsPayload },
                fba.allocator(), resp, .{}) catch return c.GIT_EAUTH;

            const passphrase = parsed.value.payload.password;
            @memcpy(passphrase_buf[0..passphrase.len], passphrase);
            passphrase_buf[passphrase.len] = 0;

            const rc = c.git_credential_ssh_key_new(
                out, username_from_url, pub_path, priv_path,
                @ptrCast(&passphrase_buf),
            );
            if (rc == 0) return 0;
        }
    }

    // Fall back to asking the CLI for credentials
    if (allowed_types & c.GIT_CREDENTIAL_USERPASS_PLAINTEXT != 0) {
        const url_str = std.mem.span(url);

        // Send need_credentials to CLI
        var buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(&buf,
            "{{\"tag\":\"need_credentials\",\"payload\":{{\"url\":\"{s}\"}}}}\n",
            .{url_str}) catch return c.GIT_EAUTH;
        ctx.streamout.writeAll(req) catch return c.GIT_EAUTH;
        ctx.streamout.flush() catch return c.GIT_EAUTH;

        // Block reading credentials response
        const resp_str = ctx.streamin.takeDelimiter('\n') catch return c.GIT_EAUTH;
        const resp = resp_str orelse return c.GIT_EAUTH;

        // Parse the credentials packet
        // Using a simple fixed buffer approach since we can't allocate in a C callback
        var fba_buf: [512]u8 = undefined;
        var username_buf: [256]u8 = undefined;
        var password_buf: [256]u8 = undefined;

        // You'll need to parse the JSON here — simplest is a lightweight parse
        // or just use std.json.parseFromSliceLeaky with a fixed buffer allocator
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const parsed = std.json.parseFromSlice(
            struct { tag: []const u8, payload: CredentialsPayload },
            fba.allocator(), resp, .{}) catch return c.GIT_EAUTH;
        const creds = parsed.value.payload;

        // Copy to sentinel buffers for libgit2
        @memcpy(username_buf[0..creds.username.len], creds.username);
        username_buf[creds.username.len] = 0;
        @memcpy(password_buf[0..creds.password.len], creds.password);
        password_buf[creds.password.len] = 0;

        return c.git_credential_userpass_plaintext_new(
            out,
            @ptrCast(&username_buf),
            @ptrCast(&password_buf),
        );
    }

    return c.GIT_EAUTH;
}

// Set up a detached-gitdir repo with $HOME as the worktree — the standard
// "bare repo dotfile" trick, keeping git internals out of $HOME entirely
pub fn handleInit(
    init: std.process.Init,
    repo: *?*c.git_repository,
    remote: []const u8,
    msg: *[]const u8
) !void {
    const remote_z = try init.gpa.dupeSentinel(u8, remote, 0);
    defer init.gpa.free(remote_z);

    const home = mem.span(std.c.getenv("HOME") orelse {
        msg.* = try init.gpa.dupe(u8, "HOME is not set");
        return error.GitError;
    });

    // Tucked into ~/.local/share/configz rather than a visible .git in $HOME
    const repo_path = try std.fmt.allocPrintSentinel(init.gpa, config.bare_repo_path_fmt, .{home}, 0);
    defer init.gpa.free(repo_path);

    var opts: c.git_repository_init_options = undefined;
    _ = c.git_repository_init_options_init(&opts, c.GIT_REPOSITORY_INIT_OPTIONS_VERSION);

    // NO_DOTGIT_DIR: no .git symlink in worktree
    // MKPATH: create full gitdir hierarchy
    opts.flags = c.GIT_REPOSITORY_INIT_NO_DOTGIT_DIR | c.GIT_REPOSITORY_INIT_MKDIR | c.GIT_REPOSITORY_INIT_MKPATH;
    opts.workdir_path = @ptrCast(home);
    opts.initial_head = "main";

    // libgit2 is supposed to create the parent dirs itself but won't
    std.Io.Dir.cwd().createDirPath(init.io, repo_path) catch |err| {
        msg.* = try std.fmt.allocPrint(init.gpa, "Failed to create {s}: {s}", .{repo_path, @errorName(err)});
        return err;
    };

    const init_rc = c.git_repository_init_ext(repo, repo_path, &opts);
    if (init_rc != 0) {
        const err = c.git_error_last();
        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_repository_init_ext: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to create bare-style repo");
        return error.GitError;
    }

    var remote_obj: ?*c.git_remote = null;
    const remote_rc = c.git_remote_create(&remote_obj, repo.*, "origin", remote_z);
    if (remote_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_remote_create: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to create remote");
        return error.GitError;
    }
    defer c.git_remote_free(remote_obj);

    var cfg: ?*c.git_config = null;
    if (c.git_repository_config(&cfg, repo.*) != 0) {
        msg.* = try init.gpa.dupe(u8, "failed to get repo config");
        return error.GitError;
    }
    defer c.git_config_free(cfg);

    // Suppress untracked files — only explicitly added paths should appear in status
    _ = c.git_config_set_string(cfg, "status.showUntrackedFiles", "no");

    // Set up tracking so push/pull work without explicit refspecs
    _ = c.git_config_set_string(cfg, "branch.main.remote", "origin");
    _ = c.git_config_set_string(cfg, "branch.main.merge", "refs/heads/main");
}

// Stage requested paths into the index, replacing added_paths with only those
// that succeeded. Partial failure is allowed — failures are collected and
// returned as a single error message after the index is written
pub fn handleAdd(
    init: std.process.Init,
    repo: ?*c.git_repository,
    added_paths: *std.ArrayList([]const u8),
    msg: *[]const u8,
) !void {
    const home = mem.span(std.c.getenv("HOME") orelse {
        msg.* = try init.gpa.dupe(u8, "HOME is not set");
        return error.GitError;
    });

    var index: ?*c.git_index = null;
    const index_rc = c.git_repository_index(&index, repo);
    if (index_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_repository_index: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    var true_additions = try std.ArrayList([]const u8).initCapacity(init.gpa, added_paths.items.len);
    var true_additions_owned = true;
    // Disarmed once ownership transfers to added_paths below
    errdefer if (true_additions_owned) {
        for (true_additions.items) |item| init.gpa.free(item);
        true_additions.deinit(init.gpa);
    };

    var err_list = try std.ArrayList(u8).initCapacity(init.gpa, 0);
    defer err_list.deinit(init.gpa);

    // Free failed paths and continue — errors are collected in err_list
    for (added_paths.items) |file| {
        if (addPath(init, repo.?, index.?, home, file, &err_list)) {
            const file_dupe = try init.gpa.dupe(u8, file);
            errdefer init.gpa.free(file_dupe);
            try true_additions.append(init.gpa, file_dupe);
        } else |_| {
            init.gpa.free(file);
        }
    }

    const write_rc = c.git_index_write(index);
    if (write_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_index_write: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to write index");
        return error.GitError;
    }

    // Transfer ownership — added_paths now reflects what was actually staged
    added_paths.deinit(init.gpa);
    added_paths.* = true_additions;
    true_additions_owned = false;

    // Report any per-file failures as a single message after persisting successes
    if (err_list.items.len > 0) {
        msg.* = try std.fmt.allocPrint(init.gpa, "Some files failed to add:{s}", .{err_list.items});
        return error.GitError;
    }
}

// Recursively stage a path into the index. Directories are walked and each
// file staged individually. rel_path is relative to home — libgit2 stores it
// that way so paths in the index aren't machine-specific
fn addPath(
    init: std.process.Init,
    repo: *c.git_repository,
    index: *c.git_index,
    home: []const u8,
    rel_path: []const u8,
    err_list: *std.ArrayList(u8),
) !void {
    const full_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{ home, rel_path }, 0);
    defer init.gpa.free(full_path);

    const maybe_dir = std.Io.Dir.openDirAbsolute(init.io, full_path, .{.iterate = true});
    if (maybe_dir) |dir| {
        defer dir.close(init.io);
        var it = dir.iterate();
        while (try it.next(init.io)) |entry| {
            // Skip .git dirs to avoid staging another repo's internals.
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;

            const child_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ rel_path, entry.name });
            defer init.gpa.free(child_path);
            try addPath(init, repo, index, home, child_path, err_list);
        }
    } else |err| switch (err) {
        error.NotDir => {
            const file_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
            defer init.gpa.free(file_z);

            // Stat before blob creation so we have accurate metadata to populate
            // the index entry — libgit2 doesn't fill this in automatically
            var statx_buf: std.os.linux.Statx = undefined;
            const statx_rc = std.os.linux.statx(
                std.os.linux.AT.FDCWD,
                full_path,
                0,
                .BASIC_STATS,
                &statx_buf,
            );
            if (statx_rc != 0) {
                const msg_ptr = strerror(@intCast(-@as(isize, @bitCast(statx_rc))));
                const detail = std.mem.sliceTo(msg_ptr, 0);

                try err_list.appendSlice(init.gpa, "\n ~> ");
                try err_list.appendSlice(init.gpa, rel_path);
                try err_list.appendSlice(init.gpa, ": ");
                try err_list.appendSlice(init.gpa, detail);
                return error.GitError;
            }

            // Write file contents into the object store as a blob
            var oid: c.git_oid = undefined;
            if (c.git_blob_create_from_disk(&oid, repo, full_path) != 0) {
                try err_list.appendSlice(init.gpa, "\n ~> ");
                try err_list.appendSlice(init.gpa, rel_path);
                try err_list.appendSlice(init.gpa, ": failed to create blob");
                return error.GitError;
            }

            // Build the index entry manually with stat metadata so git status
            // can detect future changes by comparing mtime/size without re-hashing
            var entry: c.git_index_entry = std.mem.zeroes(c.git_index_entry);
            entry.path = file_z;
            entry.id = oid;
            entry.mode = @intCast(statx_buf.mode);
            entry.file_size = @intCast(statx_buf.size);
            entry.mtime.seconds = @intCast(statx_buf.mtime.sec);
            entry.mtime.nanoseconds = @intCast(statx_buf.mtime.nsec);
            entry.ctime.seconds = @intCast(statx_buf.ctime.sec);
            entry.ctime.nanoseconds = @intCast(statx_buf.ctime.nsec);

            if (c.git_index_add(index, &entry) != 0) {
                try err_list.appendSlice(init.gpa, "\n ~> ");
                try err_list.appendSlice(init.gpa, rel_path);
                try err_list.appendSlice(init.gpa, ": failed to add");
                return error.GitError;
            }
        },
        else => {
            try err_list.appendSlice(init.gpa, "\n ~> ");
            try err_list.appendSlice(init.gpa, rel_path);
            try err_list.appendSlice(init.gpa, ": failed to open");
            return error.GitError;
        },
    }
}

// Unstage requested paths from the index, replacing dropped_paths with only
// those that succeeded. Partial failure is allowed — failures are collected
// and reported after the index is written
pub fn handleDrop(
    init: std.process.Init,
    repo: ?*c.git_repository,
    dropped_paths: *std.ArrayList([]const u8), // correct the rest
    msg: *[]const u8,
) !void {
    const home = mem.span(std.c.getenv("HOME") orelse {
        msg.* = try init.gpa.dupe(u8, "HOME is not set");
        return error.GitError;
    });

    var index: ?*c.git_index = null;
    const index_rc = c.git_repository_index(&index, repo);
    if (index_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_repository_index: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to get repo index");
        return error.GitError;
    }
    defer c.git_index_free(index);

    var true_drops = try std.ArrayList([]const u8).initCapacity(init.gpa, dropped_paths.items.len);
    var true_drops_owned = true;
    // Disarmed once ownership transfers to dropped_paths below
    errdefer if (true_drops_owned) {
        for (true_drops.items) |item| init.gpa.free(item);
        true_drops.deinit(init.gpa);
    };

    var err_list = try std.ArrayList(u8).initCapacity(init.gpa, 0);
    defer err_list.deinit(init.gpa);

    // Free failed paths and continue — errors are collected in err_list
    for (dropped_paths.items) |file| {
        if (dropPath(init, index.?, home, file, &err_list)) {
            const file_dupe = try init.gpa.dupe(u8, file);
            errdefer init.gpa.free(file_dupe);
            try true_drops.append(init.gpa, file_dupe);
        } else |_| {
            init.gpa.free(file);
        }
    }

    const write_rc = c.git_index_write(index);
    if (write_rc != 0) {
        const err = c.git_error_last();

        const detail = if (err != null)
            std.mem.sliceTo(err.*.message, 0)
        else
            "unknown libgit2 error";
        std.debug.print("git_index_write: {s}\n", .{detail});

        msg.* = try init.gpa.dupe(u8, "failed to write index");
        return error.GitError;
    }

    // Transfer ownership — dropped_paths now reflects what was actually unstaged
    dropped_paths.deinit(init.gpa);
    dropped_paths.* = true_drops;
    true_drops_owned = false;

    // Report per-file failures after persisting successes
    if (err_list.items.len > 0) {
        msg.* = try std.fmt.allocPrint(init.gpa, "Some files failed to be dropped:{s}", .{err_list.items});
        return error.GitError;
    }
}

// Recursively remove a path from the index. Mirrors addPath — directories are
// walked and each file removed individually. Does not delete files from disk,
// only unstages them.
fn dropPath(
    init: std.process.Init,
    index: *c.git_index,
    home: []const u8,
    rel_path: []const u8,
    err_list: *std.ArrayList(u8),
) !void {
    const full_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{ home, rel_path }, 0);
    defer init.gpa.free(full_path);

    const maybe_dir = std.Io.Dir.openDirAbsolute(init.io, full_path, .{ .iterate = true });
    if (maybe_dir) |dir| {
        defer dir.close(init.io);
        var it = dir.iterate();
        while (try it.next(init.io)) |entry| {
            // Skip .git dirs to avoid touching another repo's internals.
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;
            const child_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ rel_path, entry.name });
            defer init.gpa.free(child_path);
            try dropPath(init, index, home, child_path, err_list);
        }
    } else |err| switch (err) {
        error.NotDir => {
            const file_z = try init.gpa.dupeSentinel(u8, rel_path, 0);
            defer init.gpa.free(file_z);

            std.log.debug("dropPath: removing '{s}' from index", .{rel_path});
            if (c.git_index_remove(index, file_z, 0) != 0) {
                try err_list.appendSlice(init.gpa, "\n ~> ");
                try err_list.appendSlice(init.gpa, rel_path);
                try err_list.appendSlice(init.gpa, ": failed to remove");
                return error.GitError;
            }
        },
        else => {
            try err_list.appendSlice(init.gpa, "\n ~> ");
            try err_list.appendSlice(init.gpa, rel_path);
            try err_list.appendSlice(init.gpa, ": failed to open");
            return error.GitError;
        },
    }
}

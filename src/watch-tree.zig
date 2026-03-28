const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const c = @import("c.zig").git2;

pub const WatchError = error {
    PathNotUnderRoot,
};

// A node in the watch tree. Each node represents a watched directory, tracking
// its inotify watch descriptor and — for file-granular watches — the specific
// filenames of interest within that directory
const PathNode = struct {
    const Self = @This();

    abs_dirname: []const u8,
    parent: ?*PathNode,
    children: std.ArrayList(*PathNode),
    watch_data: struct {
        // 0 means there's no watch
        wd: i32,
        // null means watch the whole directory. Non-null filters events to
        // specific filenames, used when a file rather than a directory was added
        file_set: ?std.ArrayList([]const u8),
    },


    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────

    // Whether this node has an active inotify watch
    pub fn active(self: Self) bool {
        return self.watch_data.wd != 0;
    }

    // The path segment from this node's parent to itself. Used to reconstruct
    // relative paths without re-allocating the full absolute path
    pub fn path_shard(self: Self) []const u8 {
        if (self.parent) |parent| {
            const parent_len = parent.abs_dirname.len;
            return self.abs_dirname[parent_len..];
        } else {
            return self.abs_dirname;
        }
    }

    // Append any new_children not already present in self.children
    // Pointer equality is used — the same node won't be adopted twice
    pub fn adopt(self: *Self, allocator: Allocator, new_children: std.ArrayList(*PathNode)) !void {
        var found = false;
        for (new_children.items) |new| {
            for (self.children.items) |old| {
                if (new == old) {
                    found = true;
                    break;
                }
            }

            if (!found) try self.children.append(allocator, new);
            found = false;
        }
    }

    // Merge additions into this node's file_set, deduplicating by filename
    // If file_set is null (whole-directory watch), additions are freed and ignored
    // If additions is null, the file_set is cleared entirely
    pub fn meshData(
        self: Self,
        allocator: Allocator,
        additions: ?std.ArrayList([]const u8)
    ) error{OutOfMemory}!void {
        var set = self.watch_data.file_set;

        if (set == null) {
            if (additions) |add| for (add.items) |file| allocator.free(file);
            return;
        }

        if (additions == null) {
            if (set) |s| {
                var ms = s;
                for (ms.items) |file| allocator.free(file);
                ms.deinit(allocator);
            }
            set = null;
            return;
        }

        var found = false;
        for (additions.?.items) |new_file| {
            for (set.?.items) |existing| {
                if (mem.eql(u8, new_file, existing)) {
                    found = true;
                    break;
                }
            }

            if (!found) try set.?.append(allocator, new_file);
            found = false;
        }
    }


    // ── Existentials ─────────────────────────────────────────────────────────────────────────────

    pub fn init(allocator: Allocator, abs_path: []const u8) error{OutOfMemory}!*Self {
        const node = try allocator.create(PathNode);

        node.* = PathNode{
            .abs_dirname = abs_path,
            .parent = null,
            .children = try std.ArrayList(*PathNode).initCapacity(allocator, 1),
            .watch_data = .{
                .wd = 0,
                .file_set = null,
            },
        };

        return node;
    }

    pub fn deinit(self: *Self, allocator: Allocator, ifd: i32) !void {
        allocator.free(self.abs_dirname);
        self.children.deinit(allocator);
        if (self.watch_data.wd != 0)
            _ = std.os.linux.inotify_rm_watch(ifd, self.watch_data.wd);
        if (self.watch_data.file_set) |set| {
            var mset = set;
            for (mset.items) |file| allocator.free(file);
            mset.deinit(allocator);
        }
    }
};

// The inotify-backed watch tree. Tracks a hierarchy of PathNodes rooted at a
// single directory. Two hashmaps provide O(1) lookup by inotify watch descriptor
// (for event dispatch) and by absolute path (for add/remove operations)
pub const Paths = struct {
    const Self = @This();

    ifd: i32,
    root: *PathNode,
    hashes: struct {
        wd_node: std.AutoHashMap(i32, *PathNode),
        path_node: std.StringHashMap(*PathNode),
    },


    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────

    // Register an inotify watch on node and store the wd in both the node and
    // the wd_node map. No-op if the node is already being watched
    pub fn startWatch(
        self: *Self,
        allocator: Allocator,
        node: *PathNode,
        file_set: ?std.ArrayList([]const u8)
    ) !void {
        if (node.watch_data.wd != 0) return;
        node.watch_data.file_set = file_set;

        const path_z = try allocator.dupeZ(u8, node.abs_dirname);
        defer allocator.free(path_z);

        const wd_raw: i32 = @intCast(std.os.linux.inotify_add_watch(self.ifd, path_z,
            std.os.linux.IN.CREATE | std.os.linux.IN.CLOSE_WRITE |
            std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
            std.os.linux.IN.MOVED_TO));

        if (wd_raw == std.math.maxInt(usize)) return error.InotifyError;
        const wd: i32 = @intCast(wd_raw);
        try self.hashes.wd_node.put(wd, node);
    }

    // Walk the tree to find the node for dirname. Returns the node and whether
    // it was an exact match. On a miss, returns the deepest ancestor found —
    // the natural insertion point for a new node
    fn find(
        self: *Self,
        dirname: []const u8
    ) (error{OutOfMemory} || WatchError)!struct{found: bool, node: *PathNode} {
        const root = self.root;
        const root_len = root.abs_dirname.len;
        if (dirname.len < root_len or
            !mem.eql(u8, dirname[0..root_len], root.abs_dirname[0..root_len])) {
            return WatchError.PathNotUnderRoot;
        }

        // Check root itself first
        if (mem.eql(u8, root.abs_dirname, dirname))
            return .{ .found = true, .node = root };

        var i: usize = 0;
        var children = root.children.items;
        var child: *PathNode = root;
        while (i < children.len) {
            child = children[i];

            if (mem.eql(u8, child.abs_dirname, dirname))
                return .{ .found = true, .node = child };
            // Descend if this child is a prefix of the target path
            if (child.abs_dirname.len <= dirname.len and
                mem.eql(u8, child.abs_dirname, dirname[0..child.abs_dirname.len])) {
                children = child.children.items;
                i = 0; // restart with new children
                continue;
            }

            i += 1;
        }

        return .{ .found = false, .node = child.parent orelse root };
    }


    // ── Existentials ─────────────────────────────────────────────────────────────────────────────

    pub fn init(allocator: Allocator, io: std.Io, dirname: []const u8) !Self {
        const file = try std.Io.Dir.openFileAbsolute(io, dirname,
            .{ .path_only = true, .follow_symlinks = true });
        const stat = try file.stat(io);

        if (stat.kind != .directory)
            return error.NotDir;

        const ifd: i32 = @intCast(std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK));
        const wd_node_hash = std.AutoHashMap(i32, *PathNode).init(allocator);
        const path_node_hash = std.StringHashMap(*PathNode).init(allocator);

        const paths = Self{
            .ifd = ifd,
            .root = try PathNode.init(allocator, try allocator.dupe(u8, dirname)),
            .hashes = .{
                .wd_node = wd_node_hash,
                .path_node = path_node_hash,
            }
        };

        return paths;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        var it = self.hashes.path_node.iterator();
        while (it.next()) |this| {
            allocator.free(this.key_ptr.*);
            this.value_ptr.*.deinit(allocator, self.ifd) catch {};
            allocator.destroy(this.value_ptr.*);
        }

        self.hashes.wd_node.deinit();
        self.hashes.path_node.deinit();

        // Root is not in either hashmap, free it explicitly
        if (self.root.watch_data.file_set) |set| {
            var mset = set;
            for (mset.items) |file| allocator.free(file);
            mset.deinit(allocator);
        }
        allocator.free(self.root.abs_dirname);
        self.root.children.deinit(allocator);
        allocator.destroy(self.root);
    }


    // ── Paths Main ───────────────────────────────────────────────────────────────────────────────

    // Register abs_path for inotify watching. Directories get a whole-directory
    // watch; files get their parent directory watched with a file_set filter so
    // events from unrelated siblings are ignored. If the node already exists,
    // its watch is updated rather than duplicated
    pub fn add(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        abs_path: []const u8,
        file_set: ?std.ArrayList([]const u8)
    ) !void {
        std.log.debug("Paths.add: {s}", .{abs_path});

        const file = try std.Io.Dir.openFileAbsolute(io, abs_path,
            .{ .path_only = true, .follow_symlinks = true });
        const stat = try file.stat(io);

        var found: bool = undefined;
        var node: *PathNode = undefined;
        if (stat.kind == .directory) {
            const find_ret = try self.find(abs_path);
            found = find_ret.found;
            node = find_ret.node;

            if (found) {
                if (node.active())
                    try node.meshData(allocator, if (file_set) |set| set else null)
                else
                    try self.startWatch(allocator, node, file_set);
            } else {
                var new_node = try PathNode.init(allocator, try allocator.dupe(u8, abs_path));
                new_node.parent = node;
                try node.children.append(allocator, new_node);
                try self.startWatch(allocator, new_node, file_set);
                try self.hashes.path_node.put(try allocator.dupe(u8, abs_path), new_node);
            }
        } else {
            // For files, watch the parent directory and track the basename in a file_set
            const dirname = std.fs.path.dirname(abs_path) orelse "";
            const find_ret = try self.find(dirname);
            found = find_ret.found;
            node = find_ret.node;

            var single_set = try std.ArrayList([]const u8).initCapacity(allocator, 1);
            try single_set.append(allocator, try allocator.dupe(u8, std.fs.path.basename(abs_path)));

            if (found) {
                if (node.active())
                    try node.meshData(allocator, single_set)
                else
                    try self.startWatch(allocator, node, single_set);
            } else {
                var new_node = try PathNode.init(allocator, try allocator.dupe(u8, dirname));
                new_node.parent = node;
                try node.children.append(allocator, new_node);
                try self.startWatch(allocator, new_node, single_set);
                try self.hashes.path_node.put(try allocator.dupe(u8, dirname), new_node);
            }
        }

        std.log.debug("Paths.add: kind={s} found={}", .{@tagName(stat.kind), found});
    }

    // Unregister abs_path from the watch tree. For directories, the node is
    // removed and its children are reparented to preserve the rest of the tree
    // For files, only the basename is removed from the parent node's file_set
    pub fn remove(self: *Self, allocator: Allocator, io: std.Io, abs_path: []const u8) !void {
        const file = try std.Io.Dir.openFileAbsolute(io, abs_path,
            .{ .path_only = true, .follow_symlinks = true });
        const stat = try file.stat(io);

        if (stat.kind == .directory) {
            if (self.hashes.path_node.get(abs_path)) |node| {
                try node.parent.?.adopt(allocator, node.children);
                try node.deinit(allocator, self.ifd);
            }
        } else {
            const dirname = std.fs.path.dirname(abs_path);
            const basename = std.fs.path.basename(abs_path);

            if (dirname == null) return;
            const node = self.hashes.path_node.get(dirname.?) orelse blk: {
                // dirname may be root, which is not in path_node
                if (mem.eql(u8, dirname.?, self.root.abs_dirname)) break :blk self.root;
                return;
            };
            if (node.watch_data.file_set == null) return;

            for (node.watch_data.file_set.?.items, 0..) |item, i| {
                if (mem.eql(u8, item, basename)) {
                    allocator.free(node.watch_data.file_set.?.items[i]);
                    _ = node.watch_data.file_set.?.orderedRemove(i);
                    return;
                }
            }
        }
    }

    // Persist explicitly watched directories (those with no file_set filter) to a
    // file, one per line. Skips parent directories created implicitly for file-granular
    // watches, and any paths that no longer exist on disk
    pub fn writeWatchedDirs(self: *Self, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        var w = &writer.interface;

        var it = self.hashes.path_node.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.watch_data.file_set != null) continue; // file-granular watch, skip
            const maybe_dir = std.Io.Dir.openDirAbsolute(io, entry.key_ptr.*, .{});
            if (maybe_dir) |dir| {
                dir.close(io);
                try w.print("{s}\n", .{entry.key_ptr.*});
            } else |_| {}
        }
        try w.flush();
    }
};


// ── Testing ──────────────────────────────────────────────────────────────────────────────────────
// It was a real struggle to get this working properly — hence the EXTENSIVE testing
// I'm not too experienced and it was the only way I could get it working

test "Paths.find - path not under root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    const result = paths.find("/nonexistent/path");
    try std.testing.expectError(WatchError.PathNotUnderRoot, result);
}

test "Paths.find - exact root match returns root node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    const result = try paths.find(tmp_path);
    try std.testing.expect(result.found);
}

test "Paths.add - directory creates node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const sub_path = try std.fmt.allocPrint(allocator, "{s}/subdir", .{tmp_path});
    defer allocator.free(sub_path);

    // Create a real subdirectory inside tmp
    try std.Io.Dir.createDirAbsolute(io, sub_path, @enumFromInt(0o755));

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    try paths.add(allocator, io, sub_path, null);
    const result = try paths.find(sub_path);
    try std.testing.expect(result.found);
}

test "Paths.find - descendant not in tree returns closest ancestor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    const deep = try std.fmt.allocPrint(allocator, "{s}/a/b/c", .{tmp_path});
    defer allocator.free(deep);

    const result = try paths.find(deep);
    try std.testing.expect(!result.found);
    try std.testing.expectEqual(paths.root, result.node);
}

test "Paths.add - file creates node with file_set" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
    defer allocator.free(file_path);

    // Create the file
    const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    f.close(io);

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    try paths.add(allocator, io, file_path, null);

    // The parent directory node should exist and have a file_set containing "test.txt"
    const result = try paths.find(tmp_path);
    try std.testing.expect(result.found);
    try std.testing.expect(result.node.watch_data.file_set != null);
    try std.testing.expectEqualStrings("test.txt", result.node.watch_data.file_set.?.items[0]);
}

test "Paths.add - adding same directory twice is idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const sub_path = try std.fmt.allocPrint(allocator, "{s}/subdir", .{tmp_path});
    defer allocator.free(sub_path);
    try std.Io.Dir.createDirAbsolute(io, sub_path, @enumFromInt(0o755));

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    try paths.add(allocator, io, sub_path, null);
    try paths.add(allocator, io, sub_path, null);

    // Should still be exactly one child of root
    try std.testing.expectEqual(@as(usize, 1), paths.root.children.items.len);
}

test "Paths.remove - file is removed from file_set" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
    defer allocator.free(file_path);
    const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    f.close(io);

    var paths = try Paths.init(allocator, io, tmp_path);
    defer paths.deinit(allocator);

    try paths.add(allocator, io, file_path, null);
    try paths.remove(allocator, io, file_path);

    const result = try paths.find(tmp_path);
    try std.testing.expectEqual(@as(usize, 0), result.node.watch_data.file_set.?.items.len);
}

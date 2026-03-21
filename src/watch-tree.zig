const std = @import("std");
const c = @import("c.zig").git2;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const WatchError = error {
    PathNotUnderRoot,
};

const PathNode = struct {
    const Self = @This();

    abs_dirname: []const u8,
    parent: ?*PathNode,
    children: std.ArrayList(*PathNode),
    watch_data: struct {
        wd: i32,
        file_set: ?std.ArrayList([]const u8),
    },

    pub fn active(self: Self) bool {
        return self.watch_data.wd != 0;
    }

    pub fn path_shard(self: Self) []const u8 {
        if (self.parent) |parent| {
            const parent_len = parent.abs_dirname.len;
            return self.abs_dirname[parent_len..];
        } else {
            return self.abs_dirname;
        }
    }

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

pub const Paths = struct {
    const Self = @This();

    ifd: i32,
    root: *PathNode,
    hashes: struct {
        wd_node: std.AutoHashMap(i32, *PathNode),
        path_node: std.StringHashMap(*PathNode),
    },

    pub fn startWatch(self: *Self, node: *PathNode, file_set: ?std.ArrayList([]const u8)) !void {
        if (node.watch_data.wd != 0) return;
        node.watch_data.file_set = file_set;

        const wd: i32 = @intCast(std.os.linux.inotify_add_watch(self.ifd, @ptrCast(node.abs_dirname),
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
            std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM |
            std.os.linux.IN.MOVED_TO));
        try self.hashes.wd_node.put(wd, node);
    }

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

        var i: usize = 0;
        var children = root.children.items;
        var child: *PathNode = root;
        while (i < children.len) : (i += 1) {
            child = children[i];

            if (mem.eql(u8, child.abs_dirname, dirname)) {
                return .{ .found = true, .node = child };
            }
            if (mem.eql(u8, child.abs_dirname, dirname[0..child.abs_dirname.len])) {
                children = child.children.items;
                i = 0; // restart with new children
            }
        }

        return .{ .found = false, .node = child.parent orelse root };
    }

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

    pub fn deinit(self: *Self, allocator: Allocator) !void {
        var it = self.hashes.wd_node.iterator();
        while (it.next()) |this| {
            this.value_ptr.deinit(allocator, self.ifd);
        }
        it = self.hashes.path_node.iterator();
        while (it.next()) |this| {
            this.value_ptr.deinit(allocator, self.ifd);
        }

        self.hashes.wd_node.deinit();
        self.hashes.path_node.deinit();
    }

    pub fn add(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        abs_path: []const u8,
        file_set: ?std.ArrayList([]const u8)
    ) !void {
        const file = try std.Io.Dir.openFileAbsolute(io, abs_path,
            .{ .path_only = true, .follow_symlinks = true });
        const stat = try file.stat(io);

        if (stat.kind == .directory) {
            const find_ret = try self.find(abs_path);
            const found = find_ret.found;
            const node = find_ret.node;

            if (found) {
                if (node.active())
                    try node.meshData(allocator, if (file_set) |set| set else null)
                else
                    try self.startWatch(node, file_set);
            } else {
                var new_node = try PathNode.init(allocator, try allocator.dupe(u8, abs_path));
                new_node.parent = node;
                try self.startWatch(new_node, file_set);
                try self.hashes.path_node.put(try allocator.dupe(u8, abs_path), node);
            }
        } else {
            const dirname = std.fs.path.dirname(abs_path) orelse "";
            const find_ret = try self.find(dirname);
            const found = find_ret.found;
            const node = find_ret.node;

            var single_set = try std.ArrayList([]const u8).initCapacity(allocator, 1);
            try single_set.append(allocator, try allocator.dupe(u8, std.fs.path.basename(abs_path)));

            if (found) {
                if (node.active())
                    try node.meshData(allocator, single_set)
                else
                    try self.startWatch(node, single_set);
            } else {
                var new_node = try PathNode.init(allocator, try allocator.dupe(u8, abs_path));
                new_node.parent = node;
                try self.startWatch(new_node, single_set);
                try self.hashes.path_node.put(try allocator.dupe(u8, abs_path), node);
            }
        }
    }

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
            if (self.hashes.path_node.get(dirname.?)) |node| {
                if (node.watch_data.file_set == null) return;

                for (node.watch_data.file_set.?.items, 0..) |item, i| {
                    if (mem.eql(u8, item, basename)) {
                        _ = node.watch_data.file_set.?.orderedRemove(i);
                        return;
                    }
                }
            }
        }
    }
};

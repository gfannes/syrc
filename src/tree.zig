const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedName,
    ExpectedContent,
    ExpectedChecksum,
    ExpectedFlags,
    ExpectedTimestamp,
    ExpectedOffsets,
    WrongChecksumSize,
};

pub const FileState = struct {
    const Self = @This();

    a: std.mem.Allocator,
    path: ?[]const u8 = null,
    name: []const u8 = &.{},
    content: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: Attributes = .{},
    timestamp: Timestamp = 0,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.path) |path|
            self.a.free(path);
        self.a.free(self.name);
        if (self.content) |data|
            self.a.free(data);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.path) |path|
            try tw.writeLeaf(path, 3);
        try tw.writeLeaf(self.name, 5);

        {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (self.attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.execute) 1 else 0;
            try tw.writeLeaf(flags, 7);
        }

        try tw.writeLeaf(self.timestamp, 9);

        if (self.content) |content|
            try tw.writeLeaf(content, 11);

        if (self.checksum) |cs|
            try tw.writeLeaf(&cs, 13);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        self.path = undefined;
        if (!try tr.readLeaf(&self.path.?, 3, self.a))
            self.path = null;

        if (!try tr.readLeaf(&self.name, 5, self.a))
            return Error.ExpectedName;

        var flags: u3 = undefined;
        if (!try tr.readLeaf(&flags, 7, {}))
            return Error.ExpectedFlags;

        if (!try tr.readLeaf(&self.timestamp, 9, {}))
            return Error.ExpectedTimestamp;

        while (true) {
            const header = try tr.readHeader();
            switch (header.id) {
                11 => {
                    self.content = undefined;
                    if (!try tr.readLeaf(&self.content.?, header.id, self.a))
                        return Error.ExpectedContent;
                },
                13 => {
                    var checksum: []const u8 = undefined;
                    if (!try tr.readLeaf(&checksum, header.id, self.a))
                        return Error.ExpectedChecksum;
                    if (checksum.len != @sizeOf(crypto.Checksum))
                        return Error.WrongChecksumSize;
                    self.checksum = undefined;
                    if (self.checksum) |*cs|
                        std.mem.copyForwards(u8, cs, checksum);
                },
                else => break,
            }
        }
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("tree.FileState");
        defer node.deinit();
        if (self.path) |path|
            node.attr("path", path);
        node.attr("name", self.name);
        if (self.content) |content|
            node.attr("content", content.len);
        if (self.checksum) |checksum| {
            var buffer: [2 * 20]u8 = undefined;
            for (checksum, 0..) |byte, ix0| {
                const ix = 2 * ix0;
                _ = std.fmt.bufPrint(buffer[ix .. ix + 2], "{x:0>2}", .{byte}) catch unreachable;
            }
            node.attr("checksum", &buffer);
        }
    }
};

pub const Attributes = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
};

pub const Timestamp = u32;

pub const FileStates = std.ArrayList(FileState);

pub fn collectFileStates(dir: std.fs.Dir, a: std.mem.Allocator) !FileStates {
    const Collector = struct {
        const My = @This();

        a: std.mem.Allocator,
        dir: std.fs.Dir,
        file_states: FileStates,
        walker: rubr.walker.Walker,
        total_size: u64 = 0,

        fn init(dirr: std.fs.Dir, aa: std.mem.Allocator) My {
            return My{ .dir = dirr, .a = aa, .file_states = FileStates.init(aa), .walker = rubr.walker.Walker.init(aa) };
        }
        fn deinit(my: *My) void {
            for (my.file_states.items) |*item|
                item.deinit();
            my.file_states.deinit();
            my.walker.deinit();
        }

        fn collect(my: *My) !void {
            try my.walker.walk(std.fs.cwd(), my);
        }

        pub fn call(my: *My, dirr: std.fs.Dir, path: []const u8, maybe_offsets: ?rubr.walker.Offsets, kind: rubr.walker.Kind) !void {
            if (kind == rubr.walker.Kind.File) {
                const offsets = maybe_offsets orelse return Error.ExpectedOffsets;

                const file = try dirr.openFile(path, .{});
                defer file.close();

                const stat = try file.stat();
                const my_size = stat.size;
                my.total_size += my_size;
                std.debug.print("Path: {s}, my size: {}, total_size: {}\n", .{ path, my_size, my.total_size });

                const r = file.reader();

                var file_state = FileState.init(my.a);
                if (offsets.name != offsets.base)
                    file_state.path = try my.a.dupe(u8, path[offsets.base .. offsets.name - 1]);
                file_state.name = try my.a.dupe(u8, path[offsets.name..]);
                const content = try r.readAllAlloc(my.a, my_size);
                file_state.content = content;
                file_state.checksum = crypto.checksum(content);

                try my.file_states.append(file_state);
            }
        }
    };

    var collector = Collector.init(dir, a);
    defer collector.deinit();

    try collector.collect();

    var res = FileStates.init(a);
    std.mem.swap(FileStates, &res, &collector.file_states);

    return res;
}

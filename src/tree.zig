const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedName,
    ExpectedSize,
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
    size: usize = 0,
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
        if (self.content) |content|
            self.a.free(content);
        self.a.free(self.name);
    }

    pub fn filename(self: Self, a: std.mem.Allocator) ![]const u8 {
        if (self.path) |path| {
            const parts = [_][]const u8{ path, "/", self.name };
            return std.mem.concat(a, u8, &parts);
        } else {
            return a.dupe(u8, self.name);
        }
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.path) |path|
            try tw.writeLeaf(path, 3);
        try tw.writeLeaf(self.name, 5);
        try tw.writeLeaf(self.size, 7);

        {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (self.attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.execute) 1 else 0;
            try tw.writeLeaf(flags, 9);
        }

        try tw.writeLeaf(self.timestamp, 11);

        if (self.checksum) |cs|
            try tw.writeLeaf(&cs, 13);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        self.path = undefined;
        if (!try tr.readLeaf(&self.path.?, 3, self.a))
            self.path = null;

        if (!try tr.readLeaf(&self.name, 5, self.a))
            return Error.ExpectedName;

        if (!try tr.readLeaf(&self.size, 7, {}))
            return Error.ExpectedSize;

        var flags: u3 = undefined;
        if (!try tr.readLeaf(&flags, 9, {}))
            return Error.ExpectedFlags;
        self.attributes = .{
            .read = flags & (1 << 2) != 0,
            .write = flags & (1 << 1) != 0,
            .execute = flags & (1 << 0) != 0,
        };

        if (!try tr.readLeaf(&self.timestamp, 11, {}))
            return Error.ExpectedTimestamp;

        while (true) {
            const header = try tr.readHeader();
            switch (header.id) {
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
            node.attr("content_size", content.len);
        node.attr("size", self.size);
        {
            var attr: [3]u8 = .{ '-', '-', '-' };
            if (self.attributes.read)
                attr[0] = 'r';
            if (self.attributes.write)
                attr[1] = 'w';
            if (self.attributes.execute)
                attr[2] = 'x';
            node.attr("attr", &attr);
        }
        if (self.checksum) |checksum| {
            var buffer: [2 * rubr.util.arrayLenOf(crypto.Checksum)]u8 = undefined;
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

pub fn collectFileStates(env: Env, dir: std.fs.Dir) !FileStates {
    const Collector = struct {
        const My = @This();
        const Buffer = std.ArrayList(u8);

        env: Env,
        dir: std.fs.Dir,
        file_states: FileStates = .{},
        walker: rubr.walker.Walker,
        total_size: u64 = 0,
        // If buffer is present, it will be used to read-in content iso FileState.content
        buffer: ?Buffer = null,

        fn init(dirr: std.fs.Dir, envv: Env) My {
            return My{ .dir = dirr, .env = envv, .walker = rubr.walker.Walker{ .env = envv } };
        }
        fn deinit(my: *My) void {
            for (my.file_states.items) |*item|
                item.deinit();
            my.file_states.deinit(my.env.a);
            my.walker.deinit();
            if (my.buffer) |*buf|
                buf.deinit(my.env.a);
        }

        fn collect(my: *My) !void {
            try my.walker.walk(my.dir, my);
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

                var buffer: [1024]u8 = undefined;
                var r = file.reader(my.env.io, &buffer);

                var file_state = FileState.init(my.env.a);
                if (offsets.name != offsets.base)
                    file_state.path = try my.env.a.dupe(u8, path[offsets.base .. offsets.name - 1]);
                file_state.name = try my.env.a.dupe(u8, path[offsets.name..]);
                file_state.size = my_size;

                const mode: u16 = @intCast(stat.mode);
                file_state.attributes = .{
                    .read = mode & (1 << 8) != 0,
                    .write = mode & (1 << 7) != 0,
                    .execute = mode & (1 << 6) != 0,
                };

                var content: []u8 = &.{};
                if (my.buffer) |*buf| {
                    try buf.resize(my.env.a, my_size);
                    content = buf.items;
                } else {
                    content = try file_state.a.alloc(u8, my_size);
                    file_state.content = content;
                }

                try r.interface.readSliceAll(content);
                file_state.checksum = crypto.checksum(content);

                try my.file_states.append(my.env.a, file_state);
            }
        }
    };

    var collector = Collector.init(dir, env);
    defer collector.deinit();

    try collector.collect();

    var res = FileStates{};
    std.mem.swap(FileStates, &res, &collector.file_states);

    return res;
}

const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");
const Env = @import("Env.zig");

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
        node.attr("size", self.size);
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

pub fn collectFileStates(dir: std.fs.Dir, env: Env) !FileStates {
    const Collector = struct {
        const My = @This();
        const Buffer = std.ArrayList(u8);

        env: Env,
        dir: std.fs.Dir,
        file_states: FileStates = .{},
        walker: rubr.walker.Walker,
        total_size: u64 = 0,
        buffer: Buffer = .{},

        fn init(dirr: std.fs.Dir, envv: Env) My {
            return My{ .dir = dirr, .env = envv, .walker = rubr.walker.Walker.init(envv.a, envv.io) };
        }
        fn deinit(my: *My) void {
            for (my.file_states.items) |*item|
                item.deinit();
            my.file_states.deinit(my.env.a);
            my.walker.deinit();
            my.buffer.deinit(my.env.a);
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

                try my.buffer.resize(my.env.a, my_size);
                const content = my.buffer.items;
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

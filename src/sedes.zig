const std = @import("std");
const tree = @import("tree.zig");
const util = @import("util.zig");

// &todo: Move to rubr

// sw: SimpleWriter
// - sw.writeAll()
// tw: TreeWriter
// - tw.writeLeaf()
// - tw.writeComposite()
// tr: TreeReader
// - tw.readLeaf()
// - tw.readComposite()

pub const Error = error{
    TooLarge,
    ExpectedTypeId,
    EndOfStream,
};

// Util for working with a SimpleWriter
pub fn writeUInt(u: anytype, sw: anytype) !void {
    const T = @TypeOf(u);
    const len = (@bitSizeOf(T) - @clz(u) + 7) / 8;
    var buffer: [8]u8 = undefined;
    var uu: u128 = u;
    for (0..len) |ix| {
        buffer[len - ix - 1] = @truncate(uu);
        uu >>= 8;
    }
    try sw.writeAll(buffer[0..len]);
}
pub fn readUInt(T: type, size: usize, sr: anytype) !T {
    if (size > @sizeOf(T))
        return Error.TooLarge;
    var buffer: [@sizeOf(T)]u8 = undefined;
    const slice = buffer[0..size];
    if (try sr.readAll(slice) != size)
        return Error.EndOfStream;
    var u: T = 0;
    for (slice) |byte| {
        u <<= 8;
        u |= @as(T, byte);
    }
    return u;
}
pub fn writeVLC(u: anytype, sw: anytype) !void {
    var uu: u128 = u;
    const max_byte_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;

    var buffer: [max_byte_count]u8 = undefined;
    const len = @max((@bitSizeOf(@TypeOf(uu)) - @clz(uu) + 6) / 7, 1);
    for (0..len) |ix| {
        const data: u7 = @truncate(uu);
        uu >>= 7;

        const msbit: u8 = if (ix == 0) 0x00 else 0x80;

        buffer[len - ix - 1] = msbit | @as(u8, data);
    }

    try sw.writeAll(buffer[0..len]);
}
// Note: If reading a VLC of type T fails (eg., due to size constraint), there is no roll-back on 'sr'
pub fn readVLC(T: type, sr: anytype) !T {
    var uu: u128 = 0;
    const max_byte_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;
    for (0..max_byte_count) |ix| {
        var ary: [1]u8 = undefined;
        const count = try sr.readAll(&ary);
        if (count == 0)
            return Error.EndOfStream;
        const byte = ary[0];
        const data: u7 = @truncate(byte);
        uu <<= 7;
        uu |= @as(u128, data);

        // Check msbit to see if we need to continue
        const msbit = byte >> 7;
        if (msbit == 0)
            break;

        if (ix + 1 == max_byte_count)
            return Error.TooLarge;
    }
    return std.math.cast(T, uu) orelse return Error.TooLarge;
}

pub fn TreeWriter(Out: anytype) type {
    return struct {
        const Self = @This();

        out: Out,

        pub fn writeLeaf(self: Self, obj: anytype) !void {
            const T = @TypeOf(obj);
            if (comptime util.isStringType(T)) {
                try self.writeLeaf(String{ .str = obj });
            } else if (comptime util.isUIntType(T)) |_| {
                try self.writeLeaf(UInt{ .u = obj });
            } else {
                var counter = Counter{};
                try obj.writeLeaf(&counter);

                const type_id = comptime getTypeId(T);
                if (comptime !isLeaf(type_id)) @compileError(std.fmt.comptimePrint("Leaf '{s}' should have odd TypeId, not {},", .{ @typeName(T), type_id }));
                try writeVLC(type_id, self.out);
                try writeVLC(counter.size, self.out);
                try obj.writeLeaf(self.out);
            }
        }
        pub fn writeComposite(self: Self, obj: anytype) !void {
            const T = @TypeOf(obj);
            const type_id = comptime getTypeId(T);
            if (comptime !isComposite(type_id)) @compileError(std.fmt.comptimePrint("Composite '{s}' should have even TypeId, not {},", .{ @typeName(T), type_id }));
            try writeVLC(type_id, self.out);
            try obj.writeComposite(self);
            try writeVLC(close, self.out);
        }
    };
}

pub fn TreeReader(In: anytype) type {
    return struct {
        const Self = @This();
        const Header = struct {
            type_id: TypeId,
            size: usize = 0,
        };

        in: In,
        header: ?Header = null,

        // Returns false if there is a TypeId mismatch
        pub fn readLeaf(self: *Self, obj: anytype, ctx: anytype) !bool {
            const T = @TypeOf(obj.*);
            if (comptime util.isStringType(T)) {
                var string = String{};
                const ret = try self.readLeaf(&string, ctx);
                obj.* = string.str;
                return ret;
            } else if (comptime util.isUIntType(T)) |_| {
                var uint = UInt{};
                const ret = try self.readLeaf(&uint, ctx);
                obj.* = std.math.cast(T, uint.u) orelse return Error.TooLarge;
                return ret;
            } else {
                const header = try self.readHeader();

                if (!isLeaf(header.type_id))
                    return false;
                if (getTypeIdOf(obj) != header.type_id)
                    return false;

                const size = header.size;
                self.header = null;

                try obj.readLeaf(size, self.in, ctx);

                return true;
            }
        }

        // Returns false if there is a TypeId mismatch
        pub fn readComposite(self: *Self, obj: anytype, ctx: anytype) !bool {
            {
                const header = try self.readHeader();

                if (!isComposite(header.type_id)) {
                    std.debug.print("Expected composite, received {}\n", .{header.type_id});
                    return false;
                }
                if (getTypeIdOf(obj) != header.type_id) {
                    std.debug.print("Expected {}, found {}\n", .{ getTypeIdOf(obj), header.type_id });
                    return false;
                }
                self.header = null;
            }

            try obj.readComposite(self, ctx);

            {
                const header = try self.readHeader();
                if (header.type_id != close) {
                    std.debug.print("Expected close ({}), found {}\n", .{ close, header.type_id });
                    return false;
                }
                self.header = null;
            }

            return true;
        }

        pub fn readHeader(self: *Self) !Header {
            if (self.header) |header|
                return header;

            const type_id = try readVLC(TypeId, self.in);
            const size = if (isLeaf(type_id)) try readVLC(usize, self.in) else 0;
            const header = Header{ .type_id = type_id, .size = size };
            self.header = header;
            return header;
        }

        pub fn isClose(self: *Self) !bool {
            const header = try self.readHeader();
            return header.type_id == close;
        }
    };
}

test "leaf" {
    const ut = std.testing;

    const filename = "leaf.dat";

    // Create a file with some leaf data
    {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        const tw = TreeWriter(std.fs.File){ .out = file };
        try tw.writeLeaf(@as(u32, 1234));
        try tw.writeLeaf("string");
    }

    // Read the content using wrapper classes
    {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var tr = TreeReader(std.fs.File){ .in = file };

        var uint = UInt{};
        try ut.expect(try tr.readLeaf(&uint, {}));
        try ut.expectEqual(uint.u, 1234);

        var string = String{};
        try ut.expect(try tr.readLeaf(&string, ut.allocator));
        defer ut.allocator.free(string.str);
        try ut.expectEqualStrings("string", string.str);
    }

    // Read the content using primitive data types
    {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var tr = TreeReader(std.fs.File){ .in = file };

        var u: u32 = undefined;
        try ut.expect(try tr.readLeaf(&u, {}));
        try ut.expectEqual(u, 1234);

        var string = String{};
        try ut.expect(try tr.readLeaf(&string, ut.allocator));
        defer ut.allocator.free(string.str);
        try ut.expectEqualStrings("string", string.str);
    }
}

const Composite = struct {
    const Self = @This();
    str: []const u8 = "composite",
    fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.str);
    }
    fn readComposite(self: *Self, tr: anytype, a: std.mem.Allocator) !void {
        try tr.readLeaf(&self.str, a);
    }
};
test "composite" {
    const file = try std.fs.cwd().createFile("composite.dat", .{});
    defer file.close();

    const tw = TreeWriter(std.fs.File){ .out = file };

    const comp = Composite{};
    try tw.writeComposite(comp);
}

// SimpleWriter that counts the byte size of a leaf
const Counter = struct {
    const Self = @This();
    size: usize = 0,
    pub fn writeAll(self: *Self, ary: []const u8) !void {
        self.size += ary.len;
    }
};

// Wrapper classes for primitives to support obj.writeLeaf()
const String = struct {
    const Self = @This();
    str: []const u8 = &.{},
    fn writeLeaf(self: Self, sw: anytype) !void {
        try sw.writeAll(self.str);
    }
    fn readLeaf(self: *Self, size: usize, sr: anytype, a: std.mem.Allocator) !void {
        const slice = try a.alloc(u8, size);
        if (try sr.readAll(slice) != size)
            return Error.EndOfStream;
        self.str = slice;
    }
};
const UInt = struct {
    const Self = @This();
    u: u128 = 0,
    fn writeLeaf(self: Self, sw: anytype) !void {
        try writeUInt(self.u, sw);
    }
    fn readLeaf(self: *Self, size: usize, sr: anytype, _: void) !void {
        self.u = try readUInt(@TypeOf(self.u), size, sr);
    }
};

const TypeId = usize;
const stop = 0;
const close = 1;
fn getTypeId(comptime T: type) TypeId {
    const type_id = switch (util.baseType(T)) {
        // Composites are even
        tree.Replicate => 2,
        tree.FileState => 4,
        Composite => 6,

        // Leafs are odd
        String => 3,
        UInt => 5,

        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    };
    if (type_id == 0 or type_id == 1)
        @compileError("TypeId 0 and 1 are reserved");
    return type_id;
}
fn getTypeIdOf(obj: anytype) TypeId {
    return getTypeId(@TypeOf(obj));
}

fn isLeaf(type_id: TypeId) bool {
    return util.isOdd(type_id) and type_id >= 3;
}
fn isComposite(type_id: TypeId) bool {
    return util.isEven(type_id) and type_id >= 2;
}

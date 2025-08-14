const std = @import("std");
const tree = @import("tree.zig");
const util = @import("util.zig");

// sw: SimpleWriter
// - sw.writeAll()
// tw: TreeWriter
// - tw.writeLeaf()
// - tw.writeComposite()

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
pub fn writeVLC(u: anytype, sw: anytype) !void {
    var uu: u128 = u;
    const max_read_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;

    var buffer: [max_read_count]u8 = undefined;
    const len = (@bitSizeOf(@TypeOf(uu)) - @clz(uu) + 6) / 7;
    for (0..len)|ix|{
        const data: u7 = @truncate(uu);
        uu >>= 7;

        const msbit:u8 = if (ix == 0) 0x00 else 0x80;
        
        buffer[len-ix-1] = msbit | @as(u8, data);
    }

    try sw.writeAll(buffer[0..len]);
}
// Note: If reading a VLC of type T fails (eg., due to size constraint), there is no roll-back on 'sr'
pub fn readVLC(T: type, sr: anytype) !T {
    var uu: u128 = 0;
    const max_read_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;
    for (0..max_read_count) |ix| {
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

        if (ix + 1 == max_read_count)
            return Error.TooLarge;
    }
    return std.math.cast(T, uu) orelse return Error.TooLarge;
}

// SimpleWriter that counts the byte size of a leaf
const Counter = struct {
    const Self = @This();
    size: usize = 0,
    pub fn writeAll(self: *Self, ary: []const u8) !void {
        self.size += ary.len;
    }
};

pub const TreeWriter = struct {
    const Self = @This();

    out: std.fs.File,

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

pub const TreeReader = struct {
    const Self = @This();
    const Header = struct {
        type_id: TypeId,
        size: usize = 0,
    };
    in: std.fs.File,
    header: ?Header = null,
    pub fn readLeaf(self: *Self, obj: anytype) !bool {
        const header = try self.readHeader();

        if (!isLeaf(header.type_id))
            return false;
        if (getTypeIdOf(obj) != header.type_id)
            return false;

        try obj.readLeaf(self.in);

        return true;
    }

    fn readHeader(self: *Self) !Header {
        if (self.header) |header| {
            return header;
        }

        const type_id = try readVLC(TypeId, self.in);
        const size = if (isLeaf(type_id)) try readVLC(usize, self.in) else 0;
        const header = Header{ .type_id = type_id, .size = size };
        self.header = header;
        return header;
    }
};

test "leaf" {
    const ut = std.testing;

    const filename = "leaf.dat";
    {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        const tw = TreeWriter{ .out = file };
        try tw.writeLeaf(@as(u32, 1234));
        try tw.writeLeaf("string");
    }
    {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var tr = TreeReader{ .in = file };

        var uint = UInt{};
        try ut.expect(try tr.readLeaf(&uint));
        try ut.expectEqual(uint.u, 1234);
    }
}

const Composite = struct {
    const Self = @This();
    str: []const u8 = "composite",
    fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.str);
    }
};
test "composite" {
    const file = try std.fs.cwd().createFile("composite.dat", .{});
    defer file.close();

    const tw = TreeWriter{ .out = file };

    const comp = Composite{};
    try tw.writeComposite(comp);
}

// Wrapper classes for primitives to support obj.writeLeaf()
const String = struct {
    const Self = @This();
    str: []const u8,
    fn writeLeaf(self: Self, sw: anytype) !void {
        try sw.writeAll(self.str);
    }
};
const UInt = struct {
    const Self = @This();
    u: u128 = 0,
    fn writeLeaf(self: Self, sw: anytype) !void {
        // &todo: Switch back to writeUInt() once readUInt() is implemented
        // try writeUInt(self.u, sw);
        try writeVLC(self.u, sw);
    }
    fn readLeaf(self: *Self, sr: anytype) !void {
        self.u = try readVLC(@TypeOf(self.u), sr);
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
    return util.isOdd(type_id);
}
fn isComposite(type_id: TypeId) bool {
    return util.isEven(type_id);
}

const std = @import("std");
const tree = @import("tree.zig");
const util = @import("util.zig");

// sw: SimpleWriter
// - sw.writeAll()
// tw: TreeWriter
// - tw.leaf()
// - tw.composite()

pub const Error = error{
    TooLarge,
    ExpectedTypeId,
};

// Util for working with a SimpleWriter
pub fn writeInt(T: type, value: T, sw: anytype) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try sw.writeAll(&buffer);
}
pub fn writeVLC(u: anytype, sw: anytype) !void {
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    {
        var uu: u128 = u;
        for (&buffer) |*byte| {
            len += 1;

            const data: u7 = @truncate(uu);
            uu >>= 7;

            if (uu == 0) {
                byte.* = @as(u8, data);
                break;
            }
            byte.* = (@as(u8, 1) << 7) | data;
        }
    }

    try sw.writeAll(buffer[0..len]);
}
pub fn writeString(str: []const u8, sw: anytype) !void {
    const len = std.math.cast(u32, str.len) orelse return Error.TooLarge;
    try writeInt(u32, len, sw);
    try sw.writeAll(str);
}
pub fn writeComposite(obj: anytype, sw: anytype) !void {
    var counter = Counter{};
    try obj.write(&counter);
    const size = std.math.cast(u32, counter.size) orelse return Error.TooLarge;
    try writeInt(u32, size, sw);
    try obj.write(sw);
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

    pub fn leaf(self: Self, obj: anytype) !void {
        const T = @TypeOf(obj);
        if (comptime util.isStringType(T)) {
            try self.leaf(String{ .str = obj });
        } else if (comptime util.isUIntType(T)) |_| {
            try self.leaf(UInt{ .u = obj });
        } else {
            var counter = Counter{};
            try obj.leaf(&counter);

            const type_id = comptime getTypeId(T);
            if (comptime !util.isOdd(type_id)) @compileError(std.fmt.comptimePrint("Leaf '{s}' should have odd TypeId, not {},", .{@typeName(T), type_id}));
            try writeVLC(type_id, self.out);
            try writeVLC(counter.size, self.out);
            try obj.leaf(self.out);
        }
    }
    pub fn composite(self: Self, obj: anytype) !void {
        const T = @TypeOf(obj);
        const type_id = comptime getTypeId(T);
        if (comptime !util.isEven(type_id)) @compileError(std.fmt.comptimePrint("Composite '{s}' should have even TypeId, not {},", .{@typeName(T), type_id}));
        try writeVLC(type_id, self.out);
        try obj.composite(self);
        try writeVLC(close, self.out);
    }
};
test "TreeWriter.leaf" {
    const file = try std.fs.cwd().createFile("leaf.dat", .{});
    defer file.close();

    const tw = TreeWriter{ .out = file };
    try tw.leaf("string");
    try tw.leaf(@as(u32, 1234));
}

const Composite = struct {
    const Self = @This();
    str: []const u8 = "composite",
    fn composite(self: Self, tw: anytype) !void {
        try tw.leaf(self.str);
    }
};
test "TreeWriter.composite" {
    const file = try std.fs.cwd().createFile("composite.dat", .{});
    defer file.close();

    const tw = TreeWriter{ .out = file };

    const comp = Composite{};
    try tw.composite(comp);
}

// Wrapper classes for primitives to support obj.leaf()
const String = struct {
    const Self = @This();
    str: []const u8,
    fn leaf(self: Self, sw: anytype) !void {
        try sw.writeAll(self.str);
    }
};
const UInt = struct {
    const Self = @This();
    u: u128,
    fn leaf(self: Self, sw: anytype) !void {
        try writeVLC(self.u, sw);
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

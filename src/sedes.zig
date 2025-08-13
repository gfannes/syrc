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
pub fn readVLC(u: anytype, sr: anytype) !void {
    var uu: u128 = 0;
    var go: bool = true;
    while (go) {
        var ary: [1]u8 = undefined;
        try sr.readAll(&ary);
        const data: u7 = @truncate(ary[0]);
        uu <<= 7;
        uu |= @as(u128, data);
        go = ary[0] >> 7;
    }
    u.* = std.math.cast(@TypeOf(u.*), uu) orelse return Error.TooLarge;
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
            if (comptime !util.isOdd(type_id)) @compileError(std.fmt.comptimePrint("Leaf '{s}' should have odd TypeId, not {},", .{ @typeName(T), type_id }));
            try writeVLC(type_id, self.out);
            try writeVLC(counter.size, self.out);
            try obj.leaf(self.out);
        }
    }
    pub fn composite(self: Self, obj: anytype) !void {
        const T = @TypeOf(obj);
        const type_id = comptime getTypeId(T);
        if (comptime !util.isEven(type_id)) @compileError(std.fmt.comptimePrint("Composite '{s}' should have even TypeId, not {},", .{ @typeName(T), type_id }));
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

pub const TreeReader = struct {
    const Self = @This();
    in: std.fs.File,
    type_id: ?TypeId = null,
    pub fn leaf(self: *Self, obj: anytype) !bool {
        if (self.type_id == null)
            self.type_id = try readVLC(self.in);
        const type_id = self.type_id orelse unreachable;

        if (getTypeIdOf(obj) != type_id)
            return false;

        try obj.readLeaf(self.in);

        return true;
    }
};

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

const std = @import("std");
const tree = @import("tree.zig");
const util = @import("util.zig");

pub const Error = error{
    TooLarge,
    ExpectedTypeId,
};

pub fn writeInt(T: type, value: T, writer: anytype) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try writer.writeAll(&buffer);
}
pub fn writeString(str: []const u8, writer: anytype) !void {
    const len = std.math.cast(u32, str.len) orelse return Error.TooLarge;
    try writeInt(u32, len, writer);
    try writer.writeAll(str);
}
pub fn writeComposite(obj: anytype, writer: anytype) !void {
    var counter = Counter{};
    try obj.write(&counter);
    const size = std.math.cast(u32, counter.size) orelse return Error.TooLarge;
    try writeInt(u32, size, writer);
    try obj.write(writer);
}

pub const Counter = struct {
    const Self = @This();

    // Byte count of all data seen, including the Ocl.open() or Ocl.leaf()
    size: usize = 0,
    checksum: u64 = 0,
    id: ?u14 = null,

    pub fn writeAll(self: *Self, ary: []const u8) !void {
        self.size += ary.len;
    }
    pub fn leaf(self: *Self, obj: anytype) !void {
        const T = @TypeOf(obj);
        if (comptime util.isStringType(T)) {
            try self.leaf(String.init(obj));
        } else {
            if (self.id == null) {
                self.id = getLeafType(@TypeOf(obj));
            }
            self.size += 8;
            try obj.wri(self);
        }
    }
    pub fn composite(self: *Self, obj: anytype) !void {
        if (self.id == null) {
            self.id = getCompositeType(@TypeOf(obj));
        }
        self.size += 8;
        try obj.wri(self);
        self.size += 8;
    }
};

pub const Writer = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: *Self, obj: anytype, id: u32, writer: anytype) !void {
        _ = self;

        const version: u32 = 1;
        try writeInt(u32, version, writer);
        try writeInt(u32, getType(@TypeOf(obj)), writer);
        try writeInt(u32, id, writer);

        try obj.write(writer);
    }
};

pub const Writ = struct {
    const Self = @This();

    out: std.fs.File,

    pub fn init(out: std.fs.File) Self {
        return Self{ .out = out };
    }

    pub fn writeAll(self: Self, data: []const u8) !void {
        try self.out.writeAll(data);
    }

    pub fn composite(self: Self, obj: anytype) !void {
        var counter = Counter{};
        try counter.composite(obj);

        const id = counter.id orelse return Error.ExpectedTypeId;
        // We remove the size for Ocl.open()
        const size = std.math.cast(u48, counter.size - 8) orelse return Error.TooLarge;

        try Ocl.open(id, size).write(self);
        try obj.wri(self);
        try Ocl.close(id, @truncate(counter.checksum)).write(self);
    }
    pub fn leaf(self: Self, obj: anytype) !void {
        const T = @TypeOf(obj);
        if (comptime util.isStringType(T)) {
            try self.leaf(String.init(obj));
        } else {
            var counter = Counter{};
            try counter.leaf(obj);

            const id = counter.id orelse return Error.ExpectedTypeId;
            // We remove the size for Ocl.open()
            const size = std.math.cast(u48, counter.size - 8) orelse return Error.TooLarge;

            try Ocl.leaf(id, size).write(self);
            try obj.wri(self);
        }
    }
};

test "Writ.leaf" {
    const file = try std.fs.cwd().createFile("string.dat", .{});
    defer file.close();

    const w = Writ.init(file);
    try w.leaf("test");
}

const Composite = struct {
    const Self = @This();
    str: []const u8 = "composite",
    fn wri(self: Self, writer: anytype) !void {
        try writer.leaf(self.str);
    }
};
test "Writ.composite" {
    const file = try std.fs.cwd().createFile("composite.dat", .{});
    defer file.close();

    const w = Writ.init(file);

    const comp = Composite{};
    try w.composite(comp);
}

const Ocl = struct {
    const Self = @This();
    const Size = u48;
    const Checksum = u48;
    const Data = union(enum) {
        open: Size,
        close: Checksum,
        leaf: Size,
    };

    id: u14,
    data: Data,

    pub fn open(id: u14, size: u48) Self {
        return Self{ .id = id, .data = .{ .open = size } };
    }
    pub fn close(id: u14, checksum: u48) Self {
        return Self{ .id = id, .data = .{ .close = checksum } };
    }
    pub fn leaf(id: u14, size: u48) Self {
        return Self{ .id = id, .data = .{ .leaf = size } };
    }

    pub fn write(self: Self, writer: anytype) !void {
        try writeInt(u64, self.pack(), writer);
    }

    fn pack(self: Self) u64 {
        var ocl: u2 = undefined;
        var data: u48 = undefined;
        switch (self.data) {
            .open => |size| {
                ocl = 1;
                data = size;
            },
            .close => |checksum| {
                ocl = 2;
                data = checksum;
            },
            .leaf => |size| {
                ocl = 3;
                data = size;
            },
        }
        return (@as(u64, ocl) << 62) | (@as(u64, self.id) << 48) | (@as(u64, data));
    }
};

pub const Reader = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

const String = struct {
    const Self = @This();
    str: []const u8,
    fn init(str: []const u8) Self {
        return Self{ .str = str };
    }
    fn wri(self: Self, writer: anytype) !void {
        try writer.writeAll(self.str);
    }
};

fn getLeafType(comptime T: type) u14 {
    return switch (T) {
        String => 1,
        else => @compileError("Unsupported leaf type '" ++ @typeName(T) ++ "'"),
    };
}
fn getCompositeType(comptime T: type) u14 {
    return switch (util.baseType(T)) {
        tree.Replicate => 1,
        Composite => 1024,
        else => @compileError("Unsupported composite type '" ++ @typeName(T) ++ "'"),
    };
}

fn getType(comptime T: type) u32 {
    return switch (util.baseType(T)) {
        tree.Replicate => 1,
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    };
}

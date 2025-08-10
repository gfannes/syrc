const std = @import("std");
const crypto = @import("crypto.zig");
const sedes = @import("sedes.zig");
const rubr = @import("rubr.zig");
const util = @import("util.zig");

pub const Error = error{
    TooLarge,
};

pub const Replicate = struct {
    const Self = @This();

    base: []const u8,
    files: []const FileState = &.{},

    pub fn write(self: Self, writer: anytype) !void {
        try sedes.writeString(self.base, writer);
        try sedes.writeInt(u32, @sizeOf(usize), writer);
        try sedes.writeInt(usize, self.files.len, writer);
        for (self.files) |file| {
            try sedes.writeComposite(file, writer);
        }
    }
};

pub const FileState = struct {
    const Self = @This();

    path: []const u8,
    data: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: ?Attributes = null,
    timestamp: ?Timestamp = null,

    pub fn write(self: Self, writer: anytype) !void {
        try sedes.writeString(self.path, writer);
    }

    pub fn print(self: Self, log: *const rubr.log.Log) !void {
        try log.print("[FileState](path:{s})", .{self.path});
        if (self.data) |data|
            try log.print("(size:{})", .{data.len});
        if (self.checksum) |checksum| {
            try log.print("(checksum:", .{});
            for (checksum) |byte|
                try log.print("{x:0>2}", .{byte});
            try log.print(")", .{});
        }
        try log.print("\n", .{});
    }
};

pub const Attributes = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
};

pub const Timestamp = u32;

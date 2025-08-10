const std = @import("std");
const crypto = @import("crypto.zig");
const rubr = @import("rubr.zig");

pub const Replicate = struct {
    base: []const u8,
    files: []const FileState = &.{},
};

pub const FileState = struct {
    const Self = @This();

    path: []const u8,
    data: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: ?Attributes = null,
    timestamp: ?Timestamp = null,

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

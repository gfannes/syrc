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

    pub fn composite(self: Self, tw: anytype) !void {
        try tw.leaf(self.base);
        try tw.leaf(self.files.len);
        for (self.files) |file| {
            try tw.composite(file);
        }
    }
};

pub const FileState = struct {
    const Self = @This();

    path: []const u8,
    data: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: Attributes = .{},
    timestamp: Timestamp = 0,

    pub fn composite(self: Self, tw: anytype) !void {
        try tw.leaf(self.path);

        const checksum: []const u8 = if (self.checksum) |cs| &cs else &.{};
        try tw.leaf(checksum);

        {
            var flags: u3 = 0;
            flags <<= 1;
            flags += if (self.attributes.read) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.write) 1 else 0;
            flags <<= 1;
            flags += if (self.attributes.execute) 1 else 0;
            try tw.leaf(flags);
        }

        try tw.leaf(self.timestamp);
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

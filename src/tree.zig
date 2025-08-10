const std = @import("std");
const crypto = @import("crypto.zig");

pub const Replicate = struct {
    base: []const u8,
    files: []const FileState = .{},
};

pub const FileState = struct {
    path: []const u8,
    data: ?[]const u8 = null,
    checksum: ?crypto.Checksum = null,
    attributes: ?Attributes = null,
    timestamp: ?Timestamp = null,
};

pub const Attributes = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
};

pub const Timestamp = u32;

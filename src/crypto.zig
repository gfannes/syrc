const std = @import("std");

// Blake3 checksum, we use 128 bit
pub const Checksum = [16]u8;

pub fn checksum(data: []const u8) Checksum {
    var cs: Checksum = undefined;
    std.crypto.hash.Blake3.hash(data, &cs, .{});
    return cs;
}

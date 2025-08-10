const std = @import("std");

// Sha1 checksum 160 bit
pub const Checksum = [20]u8;

pub fn checksum(data: []const u8) Checksum {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(data);
    return sha1.finalResult();
}

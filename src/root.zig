const std = @import("std");

pub const blob = @import("blob.zig");

test {
    const ut = std.testing;
    ut.refAllDecls(blob);
}

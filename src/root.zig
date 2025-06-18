const std = @import("std");

pub const store = @import("store.zig");

test {
    const ut = std.testing;
    ut.refAllDecls(store);
}

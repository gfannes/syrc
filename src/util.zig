const std = @import("std");

pub fn baseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| baseType(p.child), // covers *T, []T, [*]T, [*c]T
        .array => |a| baseType(a.child), // [N]T
        .optional => |o| baseType(o.child), // ?T
        .vector => |v| baseType(v.child), // @Vector(N, T)
        else => T,
    };
}

pub fn baseTypeOf(v: anytype) type {
    return baseType(@TypeOf(v));
}

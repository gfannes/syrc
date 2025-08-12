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

pub fn isStringType(T: type) bool {
    const BaseT = baseType(T);
    if (BaseT != u8)
        return false;
    return switch (@typeInfo(T)) {
        .pointer => true, // covers *T, []T, [*]T, [*c]T
        .array => true, // [N]T
        else => false,
    };
}
pub fn isString(str:anytype)bool{
    const Str = @TypeOf(str);
    return isStringType(Str);
}

test "util.isString"{
    const ut = std.testing;

    try ut.expect(isString(@as([]const u8, "abc")));
    try ut.expect(isString("abc"));
}

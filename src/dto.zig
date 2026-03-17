// When value is present: represents a define
// When value is not present: represents an undef
pub const Define = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

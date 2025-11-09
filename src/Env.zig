const std = @import("std");
const rubr = @import("rubr.zig");

const Env = @This();

a: std.mem.Allocator = undefined,
io: std.Io = undefined,
log: *const rubr.log.Log = undefined,

pub const Instance = struct {
    const Self = @This();
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    log: rubr.log.Log = undefined,
    gpa: GPA = undefined,
    io: std.Io.Threaded = undefined,

    pub fn init(self: *Self) void {
        self.log = rubr.log.Log{};
        self.gpa = GPA{};
        self.io = std.Io.Threaded.init(self.gpa.allocator());
    }
    pub fn deinit(self: *Self) void {
        self.io.deinit();
        if (self.gpa.deinit() == .leak) {
            self.log.err("Found memory leaks in Env\n", .{}) catch {};
        }
        self.log.deinit();
    }

    pub fn env(self: *Self) Env {
        return .{ .a = self.gpa.allocator(), .io = self.io.io(), .log = &self.log };
    }
};

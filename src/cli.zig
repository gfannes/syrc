const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedExeName,
    UnexpectedArgument,
};

pub const Args = struct {
    const Self = @This();

    args: rubr.cli.Args,
    exe_name: []const u8 = &.{},
    print_help: bool = false,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .args = rubr.cli.Args.init(a) };
    }
    pub fn deinit(self: *Self) void {
        self.args.deinit();
    }

    pub fn parse(self: *Self) !void {
        try self.args.setupFromOS();

        self.exe_name = (self.args.pop() orelse return Error.ExpectedExeName).arg;

        while (self.args.pop()) |arg| {
            if (arg.is("-h", "--help")) {
                self.print_help = true;
            } else {
                std.debug.print("Unexpected argument '{s}'\n", .{arg.arg});
                return Error.UnexpectedArgument;
            }
        }
    }

    pub fn printHelp(self: Self) void {
        std.debug.print("Help for {s}\n", .{self.exe_name});
        std.debug.print("    -h/--help    Print this help\n", .{});
        std.debug.print("Developed by Geert Fannes.\n", .{});
    }
};

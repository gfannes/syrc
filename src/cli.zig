const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedExeName,
    ExpectedFolder,
    ExpectedIp,
    ExpectedPort,
    ExpectedMode,
    ModeFormatError,
    UnexpectedArgument,
};

const Default = struct {
    const port: u16 = 1357;
};

pub const Mode = enum { Client, Server, Broker };

pub const Args = struct {
    const Self = @This();

    args: rubr.cli.Args,

    exe_name: []const u8 = &.{},
    print_help: bool = false,
    folder: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    port: u16 = Default.port,
    mode: ?Mode = null,

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
            } else if (arg.is("-C", "--folder")) {
                self.folder = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-a", "--ip")) {
                self.ip = (self.args.pop() orelse return Error.ExpectedIp).arg;
            } else if (arg.is("-p", "--port")) {
                self.port = try (self.args.pop() orelse return Error.ExpectedPort).as(u16);
            } else if (arg.is("-m", "--mode")) {
                const mode = (self.args.pop() orelse return Error.ExpectedMode);
                self.mode = if (mode.is("clnt", "client"))
                    Mode.Client
                else if (mode.is("srvr", "server"))
                    Mode.Server
                else if (mode.is("brkr", "broker"))
                    Mode.Broker
                else
                    return Error.ModeFormatError;
            } else {
                std.debug.print("Unexpected argument '{s}'\n", .{arg.arg});
                return Error.UnexpectedArgument;
            }
        }
    }

    pub fn printHelp(self: Self) void {
        std.debug.print("Help for {s}\n", .{self.exe_name});
        std.debug.print("    -h/--help             Print this help\n", .{});
        std.debug.print("    -C/--folder FOLDER    Folder to synchronize\n", .{});
        std.debug.print("    -a/--ip     ADDRESS   Ip address\n", .{});
        std.debug.print("    -p/--port   PORT      Port to use [optional, default is {}]\n", .{Default.port});
        std.debug.print("    -m/--model  MODE      Operation mode: 'client', 'server' and 'broker'\n", .{});
        std.debug.print("Developed by Geert Fannes.\n", .{});
    }
};

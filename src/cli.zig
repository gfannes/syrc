const std = @import("std");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedExeName,
    ExpectedNumber,
    ExpectedFolder,
    ExpectedName,
    ExpectedIp,
    ExpectedPort,
    ExpectedMode,
    ModeFormatError,
};

const Default = struct {
    const port: u16 = 1357;
    const ip: []const u8 = "0.0.0.0";
    const store_dir: []const u8 = ".cache/syrc/blob";
    const name: []const u8 = "syrc-tmp";
};

pub const Mode = enum { Client, Server, Check, Test };

pub const Args = struct {
    const Self = @This();
    pub const Strings = std.ArrayList([]const u8);

    env: Env,
    args: rubr.cli.Args = undefined,

    exe_name: []const u8 = &.{},
    print_help: bool = false,
    verbose: usize = 1,
    base: []const u8 = &.{},
    name: []const u8 = Default.name,
    ip: []const u8 = Default.ip,
    port: u16 = Default.port,
    mode: Mode = Mode.Test,
    j: usize = 0,
    reset: bool = false,
    cleanup: bool = false,
    store_path: []const u8 = Default.store_dir,
    extra: Strings = .{},

    pub fn init(self: *Self) void {
        self.args = rubr.cli.Args{ .env = self.env };
        if (std.Thread.getCpuCount()) |j|
            self.j = j
        else |_| {}
    }

    pub fn parse(self: *Self) !void {
        try self.args.setupFromOS();

        self.exe_name = (self.args.pop() orelse return Error.ExpectedExeName).arg;

        while (self.args.pop()) |arg| {
            if (arg.is("-h", "--help")) {
                self.print_help = true;
            } else if (arg.is("-v", "--verbose")) {
                self.verbose = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-j", "--jobs")) {
                self.j = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-b", "--base")) {
                self.base = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-n", "--name")) {
                self.name = (self.args.pop() orelse return Error.ExpectedName).arg;
            } else if (arg.is("-r", "--reset")) {
                self.reset = true;
            } else if (arg.is("-c", "--cleanup")) {
                self.cleanup = true;
            } else if (arg.is("-a", "--ip")) {
                self.ip = (self.args.pop() orelse return Error.ExpectedIp).arg;
            } else if (arg.is("-p", "--port")) {
                self.port = try (self.args.pop() orelse return Error.ExpectedPort).as(u16);
            } else if (arg.is("-s", "--store")) {
                self.store_path = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-m", "--mode")) {
                const mode = (self.args.pop() orelse return Error.ExpectedMode);
                self.mode = if (mode.is("clnt", "client"))
                    Mode.Client
                else if (mode.is("srvr", "server"))
                    Mode.Server
                else if (mode.is("ch", "check"))
                    Mode.Check
                else if (mode.is("test", "test"))
                    Mode.Test
                else
                    return Error.ModeFormatError;
            } else {
                try self.extra.append(self.env.aa, arg.arg);
            }
        }

        if (!std.fs.path.isAbsolute(self.base)) {
            const part = if (self.base.len == 0) "." else self.base;
            self.base = try rubr.fs.cwdPathAlloc(self.env.aa, part);
        }
        if (!std.fs.path.isAbsolute(self.store_path)) {
            self.store_path = try rubr.fs.homeDirAlloc(self.env.aa, self.store_path);
            if (self.env.log.level(1)) |w|
                try w.print("Store will be stored in '{s}'\n", .{self.store_path});
        }
    }

    pub fn printHelp(self: Self) !void {
        std.debug.print("Help for {s}\n", .{self.exe_name});
        std.debug.print("    -h/--help                  Print this help\n", .{});
        std.debug.print("    -v/--verbose     LEVEL     Verbosity level\n", .{});
        std.debug.print("    -j/--jobs        NUMBER    Number of threads to use [optional, default is {}]\n", .{self.j});
        std.debug.print("    -b/--base        FOLDER    Base folder to use [optional, default is '{s}']\n", .{try rubr.fs.cwdPathAlloc(self.env.aa, null)});
        std.debug.print("    -n/--name        NAME      Name to use [optional, default is '{s}']\n", .{Default.name});
        std.debug.print("    -r/--reset                 Force a reset of the base destination folder [optional, default is 'no']\n", .{});
        std.debug.print("    -c/--cleanup               Cleanup the base destination folder after use [optional, default is 'no']\n", .{});
        std.debug.print("    -a/--ip          ADDRESS   Ip address [optional, default is {s}]\n", .{Default.ip});
        std.debug.print("    -p/--port        PORT      Port to use [optional, default is {}]\n", .{Default.port});
        std.debug.print("    -m/--mode        MODE      Operation mode: 'client', 'server', 'check' and 'test'\n", .{});
        std.debug.print("    -s/--store       FOLDER    Folder for blob store [optional, default is $HOME/{s}]\n", .{Default.store_dir});
        std.debug.print("Developed by Geert Fannes.\n", .{});
    }
};

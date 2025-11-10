const std = @import("std");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    ExpectedExeName,
    ExpectedNumber,
    ExpectedFolder,
    ExpectedDestination,
    ExpectedIp,
    ExpectedPort,
    ExpectedMode,
    ModeFormatError,
};

const Default = struct {
    const port: u16 = 1357;
    const ip: []const u8 = "0.0.0.0";
    const base: []const u8 = "tmp";
    const store_dir: []const u8 = ".cache/syrc/blob";
};

pub const Mode = enum { Client, Server, Copy, Broker, Test };

pub const Args = struct {
    const Self = @This();
    pub const Strings = std.ArrayList([]const u8);

    env: Env,
    args: rubr.cli.Args = undefined,

    exe_name: []const u8 = &.{},
    print_help: bool = false,
    verbose: usize = 1,
    src: []const u8 = ".",
    src_buf: [std.fs.max_path_bytes]u8 = undefined,
    dst: ?[]const u8 = null,
    ip: []const u8 = Default.ip,
    port: u16 = Default.port,
    mode: Mode = Mode.Test,
    j: usize = 0,
    base: []const u8 = Default.base,
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
            } else if (arg.is("-s", "--src")) {
                self.src = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-d", "--dst")) {
                self.dst = (self.args.pop() orelse return Error.ExpectedDestination).arg;
            } else if (arg.is("-b", "--base")) {
                self.base = (self.args.pop() orelse return Error.ExpectedFolder).arg;
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
                else if (mode.is("cp", "copy"))
                    Mode.Copy
                else if (mode.is("brkr", "broker"))
                    Mode.Broker
                else if (mode.is("test", "test"))
                    Mode.Test
                else
                    return Error.ModeFormatError;
            } else {
                try self.extra.append(self.env.aa, arg.arg);
            }
        }

        if (!std.fs.path.isAbsolute(self.src)) {
            self.src = try std.fs.cwd().realpath(self.src, &self.src_buf);
        }
        if (!std.fs.path.isAbsolute(self.store_path)) {
            self.store_path = try rubr.fs.homeDirAlloc(self.env.aa, self.store_path);
            if (self.env.log.level(1)) |w|
                try w.print("Store will be stored in '{s}'\n", .{self.store_path});
        }
    }

    pub fn printHelp(self: Self) void {
        std.debug.print("Help for {s}\n", .{self.exe_name});
        std.debug.print("    -h/--help                  Print this help\n", .{});
        std.debug.print("    -v/--verbose     LEVEL     Verbosity level\n", .{});
        std.debug.print("    -j/--jobs        NUMBER    Number of threads to use [optional, default is {}]\n", .{self.j});
        std.debug.print("    -s/--src         FOLDER    Source folder to synchronize\n", .{});
        std.debug.print("    -d/--dst         DEST      Remote destination\n", .{});
        std.debug.print("    -b/--base        FOLDER    Base folder to use on remote site [optional, default is '{s}']\n", .{Default.base});
        std.debug.print("    -a/--ip          ADDRESS   Ip address [optional, default is {s}]\n", .{Default.ip});
        std.debug.print("    -p/--port        PORT      Port to use [optional, default is {}]\n", .{Default.port});
        std.debug.print("    -m/--mode        MODE      Operation mode: 'client', 'server', 'copy', 'broker' and 'test'\n", .{});
        std.debug.print("    -s/--store       FOLDER    Folder for blob store [optional, default is $HOME/{s}]\n", .{Default.store_dir});
        std.debug.print("Developed by Geert Fannes.\n", .{});
    }
};

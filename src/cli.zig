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
    verbose: usize = 0,
    base: []const u8 = &.{},
    name: []const u8 = Default.name,
    ip: []const u8 = Default.ip,
    port: u16 = Default.port,
    mode: Mode = Mode.Client,
    j: usize = 0,
    reset_folder: bool = false,
    cleanup_folder: bool = false,
    reset_store: bool = false,
    collect: bool = false,
    store_path: []const u8 = Default.store_dir,
    extra: Strings = .{},

    pub fn init(self: *Self) void {
        self.args = rubr.cli.Args{ .env = self.env };
        if (std.Thread.getCpuCount()) |j|
            self.j = j
        else |_| {}
    }

    pub fn parse(self: *Self, os_args: std.process.Args) !void {
        try self.args.setupFromOS(os_args);

        self.exe_name = (self.args.pop() orelse return Error.ExpectedExeName).arg;

        var is_extra: bool = false;

        while (self.args.pop()) |arg| {
            if (!is_extra) {
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
                } else if (arg.is("-r", "--reset-folder")) {
                    self.reset_folder = true;
                } else if (arg.is("-R", "--reset-store")) {
                    self.reset_store = true;
                } else if (arg.is("-c", "--collect")) {
                    self.collect = true;
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
                } else if (arg.is("--", "--")) {
                    is_extra = true;
                    continue;
                } else {
                    is_extra = true;
                }
            }

            if (is_extra)
                try self.extra.append(self.env.aa, arg.arg);
        }

        if (!std.fs.path.isAbsolute(self.base)) {
            const part = if (self.base.len == 0) "." else self.base;
            self.base = try rubr.fs.cwdPathAlloc(self.env.io, self.env.aa, part);
        }
        if (!std.fs.path.isAbsolute(self.store_path)) {
            self.store_path = try rubr.fs.homePathAlloc(self.env, self.store_path);
            if (self.env.log.level(1)) |w|
                try w.print("Store will be stored in '{s}'\n", .{self.store_path});
        }
    }

    pub fn printHelp(self: Self) !void {
        try self.env.stdout.print("Help for {s}\n", .{self.exe_name});
        try self.env.stdout.print("    -h/--help                      Print this help\n", .{});
        try self.env.stdout.print("    -v/--verbose         LEVEL     Verbosity level\n", .{});
        try self.env.stdout.print("    -j/--jobs            NUMBER    Number of threads to use [optional, default is {}]\n", .{self.j});
        try self.env.stdout.print("    -b/--base            FOLDER    Base folder to use [optional, default is '{s}']\n", .{try rubr.fs.cwdPathAlloc(self.env.io, self.env.aa, null)});
        try self.env.stdout.print("    -n/--name            NAME      Name to use [optional, default is '{s}']\n", .{Default.name});
        try self.env.stdout.print("    -r/--reset-folder              Force a reset of the base destination folder [optional, default is 'no']\n", .{});
        try self.env.stdout.print("    -R/--reset-store               Force a reset of peer's store [optional, default is 'no']\n", .{});
        try self.env.stdout.print("    -c/--collect                   Collect the server state back [optional, default is 'no']\n", .{});
        try self.env.stdout.print("    -a/--ip              ADDRESS   Ip address [optional, default is {s}]\n", .{Default.ip});
        try self.env.stdout.print("    -p/--port            PORT      Port to use [optional, default is {}]\n", .{Default.port});
        try self.env.stdout.print("    -m/--mode            MODE      Operation mode: 'client', 'server', 'check' and 'test'\n", .{});
        try self.env.stdout.print("    -s/--store           FOLDER    Folder for blob store [optional, default is $HOME/{s}]\n", .{Default.store_dir});
        try self.env.stdout.print("Developed by Geert Fannes.\n", .{});
    }
};

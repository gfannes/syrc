const std = @import("std");

const dto = @import("dto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedConfig,
    ExpectedExeName,
    ExpectedNumber,
    ExpectedFolder,
    ExpectedName,
    ExpectedIp,
    ExpectedPort,
    ExpectedMode,
    ExpectedDefine,
    ExpectedUndef,
    ModeFormatError,
};

const Default = struct {
    const port: u16 = 1357;
    const ip: []const u8 = "127.0.0.1";
    const store_dir: []const u8 = ".cache/syrc/blob";
    const name: []const u8 = "syrc-tmp";
};

pub const Mode = enum { Client, Server, Check, Test };

pub const Config = struct {
    const Self = @This();
    pub const Strings = std.ArrayList([]const u8);
    pub const Alias = struct {
        name: []const u8,
        ip: []const u8,
    };

    name: ?[]const u8 = null,
    exe_name: []const u8 = &.{},
    print_help: bool = false,
    verbose: usize = 0,
    base: []const u8 = &.{},
    ip: []const u8 = &.{},
    port: u16 = Default.port,
    mode: Mode = Mode.Client,
    j: usize = 0,
    reset_folder: bool = false,
    cleanup_folder: bool = false,
    reset_store: bool = false,
    collect: bool = false,
    store_path: []const u8 = Default.store_dir,
    defines: std.ArrayList(dto.Define) = .empty,
    extra: Strings = .empty,
    aliases: []Alias = &.{},
};

pub const Loader = struct {
    pub const Self = @This();

    config: Config = .{},

    io: std.Io = undefined,
    a: std.mem.Allocator = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    aa: std.mem.Allocator = undefined,
    home: rubr.fs.Path = undefined,
    args: rubr.cli.Args = undefined,

    pub fn init(self: *Self, env: rubr.Env) !void {
        self.io = env.io;
        self.a = env.a;
        self.arena = .init(env.a);
        self.aa = self.arena.allocator();
        self.home = try rubr.fs.Path.home(env.envmap);
        self.args = .{ .env = env };
    }
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn load(self: *Self, os_args: std.process.Args) !void {
        self.config = .{};

        try self.updateWithConfigFile();
        try self.updateWithCLIArgs(os_args);
    }

    fn updateWithConfigFile(self: *Self) !void {
        var f = self.home;
        try f.add(".config");
        try f.add("syrc");
        try f.add("config.zon");

        if (f.exists(self.io)) {
            std.debug.print("Loading {s} ... ", .{f.path()});
            const content = try f.readSentinel(self.io, self.a);
            defer self.a.free(content);
            self.config = try std.zon.parse.fromSliceAlloc(Config, self.aa, content, null, .{});
            std.debug.print("done\n", .{});
        }
    }
    pub fn updateWithCLIArgs(self: *Self, os_args: std.process.Args) !void {
        const config: *Config = &self.config;

        if (std.Thread.getCpuCount()) |j|
            config.j = j
        else |_| {}

        try self.args.setupFromOS(os_args);

        config.exe_name = (self.args.pop() orelse return Error.ExpectedExeName).arg;

        var is_extra: bool = false;

        while (self.args.pop()) |arg| {
            if (!is_extra) {
                if (arg.is("-h", "--help")) {
                    config.print_help = true;
                } else if (arg.is("-v", "--verbose")) {
                    config.verbose = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
                } else if (arg.is("-j", "--jobs")) {
                    config.j = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
                } else if (arg.is("-b", "--base")) {
                    config.base = (self.args.pop() orelse return Error.ExpectedFolder).arg;
                } else if (arg.is("-n", "--name")) {
                    config.name = (self.args.pop() orelse return Error.ExpectedName).arg;
                } else if (arg.is("-r", "--reset-folder")) {
                    config.reset_folder = true;
                } else if (arg.is("-R", "--reset-store")) {
                    config.reset_store = true;
                } else if (arg.is("-c", "--collect")) {
                    config.collect = true;
                } else if (arg.is("-a", "--ip")) {
                    config.ip = (self.args.pop() orelse return Error.ExpectedIp).arg;
                } else if (arg.is("-p", "--port")) {
                    config.port = try (self.args.pop() orelse return Error.ExpectedPort).as(u16);
                } else if (arg.is("-s", "--store")) {
                    config.store_path = (self.args.pop() orelse return Error.ExpectedFolder).arg;
                } else if (arg.is("-d", "--define")) {
                    const value = (self.args.pop() orelse return Error.ExpectedDefine).arg;
                    const define: dto.Define = if (std.mem.findScalar(u8, value, '=')) |ix|
                        .{ .key = value[0..ix], .value = value[ix + 1 ..] }
                    else
                        .{ .key = value, .value = &.{} };
                    try config.defines.append(self.aa, define);
                } else if (arg.is("-D", "--undef")) {
                    const value = (self.args.pop() orelse return Error.ExpectedUndef).arg;
                    try config.defines.append(self.aa, .{ .key = value });
                } else if (arg.is("-m", "--mode")) {
                    const mode = (self.args.pop() orelse return Error.ExpectedMode);
                    config.mode = if (mode.is("clnt", "client"))
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
                    if (!is_extra) {
                        if (config.ip.len == 0) {
                            var found: bool = false;
                            for (config.aliases) |alias| {
                                if (std.mem.eql(u8, config.ip, alias.name)) {
                                    config.ip = alias.ip;
                                    found = true;
                                }
                            }
                            if (found)
                                continue;
                        }
                    }
                    is_extra = true;
                }
            }

            if (is_extra)
                try config.extra.append(self.aa, arg.arg);
        }

        if (!std.fs.path.isAbsolute(config.base)) {
            const part = if (config.base.len == 0) "." else config.base;
            config.base = try rubr.fs.cwdPathAlloc(self.io, self.aa, part);
        }
        if (!std.fs.path.isAbsolute(config.store_path)) {
            var store_path = self.home;
            try store_path.add(config.store_path);
            config.store_path = try self.aa.dupe(u8, store_path.path());
        }

        if (config.ip.len == 0)
            config.ip = Default.ip;
    }

    pub fn printHelp(self: Self, w: *std.Io.Writer) !void {
        try w.print("Help for {s}\n", .{self.config.exe_name});
        try w.print("    -h/--help                      Print this help\n", .{});
        try w.print("    -v/--verbose         LEVEL     Verbosity level\n", .{});
        try w.print("    -j/--jobs            NUMBER    Number of threads to use [optional, default is {}]\n", .{self.config.j});
        try w.print("    -b/--base            FOLDER    Base folder to use [optional, default is `cwd`]\n", .{});
        try w.print("    -n/--name            NAME      Name to use [optional, default is '{s}']\n", .{Default.name});
        try w.print("    -r/--reset-folder              Force a reset of the base destination folder [optional, default is 'no']\n", .{});
        try w.print("    -R/--reset-store               Force a reset of peer's store [optional, default is 'no']\n", .{});
        try w.print("    -c/--collect                   Collect the server state back [optional, default is 'no']\n", .{});
        try w.print("    -a/--ip              ADDRESS   Ip address [optional, default is {s}]\n", .{Default.ip});
        try w.print("    -p/--port            PORT      Port to use [optional, default is {}]\n", .{Default.port});
        try w.print("    -m/--mode            MODE      Operation mode: 'client', 'server', 'check' and 'test'\n", .{});
        try w.print("    -s/--store           FOLDER    Folder for blob store [optional, default is $HOME/{s}]\n", .{Default.store_dir});
        try w.print("    -d/--define          VAR=VALUE Define environment variable for use at remote site\n", .{});
        try w.print("    -D/--undef           VAR       Undefined environment variable at remote site\n", .{});
        try w.print("Developed by Geert Fannes.\n", .{});
    }
};

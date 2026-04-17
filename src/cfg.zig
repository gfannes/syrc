const std = @import("std");
const builtin = @import("builtin");

const dto = @import("dto.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedConfig,
    ExpectedExeName,
    ExpectedNumber,
    ExpectedFolder,
    ExpectedName,
    ExpectedSuffix,
    ExpectedIp,
    ExpectedPort,
    ExpectedMode,
    ExpectedDefine,
    ExpectedUndef,
    ModeFormatError,
    FileDoesNotExist,
};

const Default = struct {
    const port: u16 = 1357;
    const ip: []const u8 = "0.0.0.0";
    const store_dir: []const u8 = ".cache/syrc/blob";
};

pub const Mode = enum { Client, Server, Check, Test };

const Strings = std.ArrayList([]const u8);

// All options merged: those from ~/.config/syrc/config.zon and CLI
pub const Config = struct {
    const Self = @This();
    pub const Alias = struct {
        name: []const u8,
        ip: []const u8,
    };

    name: []const u8 = &.{},
    suffix: ?[]const u8 = null,
    print_help: bool = false,
    verbose: usize = 1,
    base: []const u8 = &.{},
    ip: []const u8 = Default.ip,
    port: u16 = Default.port,
    mode: Mode = Mode.Client,
    j: usize = 0,
    reset_folder: bool = false,
    cleanup_folder: bool = false,
    reset_store: bool = false,
    collect: bool = false,
    store_path: []const u8 = Default.store_dir,
    defines: std.ArrayList(dto.Define) = .empty,
    aliases: []Alias = &.{},
    extra: Strings = .empty,
};

// All options that can be specified via CLI arguments
const CliArgs = struct {
    pub const Self = @This();

    exe_name: []const u8 = &.{},

    name: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    print_help: ?bool = null,
    verbose: ?usize = null,
    base: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    mode: ?Mode = null,
    j: ?usize = null,
    reset_folder: ?bool = null,
    cleanup_folder: ?bool = null,
    reset_store: ?bool = null,
    collect: ?bool = null,
    store_path: ?[]const u8 = null,
    defines: std.ArrayList(dto.Define) = .empty,
    extra_before_dashdash: Strings = .empty,
    extra_after_dashdash: Strings = .empty,

    fn load(self: *Self, aa: std.mem.Allocator, args: *rubr.cli.Args) !void {
        self.exe_name = (args.pop() orelse return error.ExpectedExeName).arg;

        var found_dashdash: bool = false;
        while (args.pop()) |arg| {
            if (!found_dashdash) {
                var handled: bool = true;

                if (arg.is("-h", "--help")) {
                    self.print_help = true;
                } else if (arg.is("-v", "--verbose")) {
                    self.verbose = try (args.pop() orelse return error.ExpectedNumber).as(usize);
                } else if (arg.is("-j", "--jobs")) {
                    self.j = try (args.pop() orelse return error.ExpectedNumber).as(usize);
                } else if (arg.is("-b", "--base")) {
                    self.base = (args.pop() orelse return error.ExpectedFolder).arg;
                } else if (arg.is("-n", "--name")) {
                    self.name = (args.pop() orelse return error.ExpectedName).arg;
                } else if (arg.is("-N", "--suffix")) {
                    self.suffix = (args.pop() orelse return error.ExpectedSuffix).arg;
                } else if (arg.is("-r", "--reset-folder")) {
                    self.reset_folder = true;
                } else if (arg.is("-R", "--reset-store")) {
                    self.reset_store = true;
                } else if (arg.is("-c", "--collect")) {
                    self.collect = true;
                } else if (arg.is("-a", "--ip")) {
                    self.ip = (args.pop() orelse return error.ExpectedIp).arg;
                } else if (arg.is("-p", "--port")) {
                    self.port = try (args.pop() orelse return error.ExpectedPort).as(u16);
                } else if (arg.is("-s", "--store")) {
                    self.store_path = (args.pop() orelse return error.ExpectedFolder).arg;
                } else if (arg.is("-D", "--define")) {
                    var define: dto.Define = .{ .key = (args.pop() orelse return error.ExpectedDefine).arg };
                    if (std.mem.findScalar(u8, define.key, '=')) |ix| {
                        if (ix + 1 < define.key.len)
                            // '=' is not the last character: there is an actual value
                            // otherwise, define.value is null and will _remove the define_
                            define.value = define.key[ix + 1 ..];
                        define.key = define.key[0..ix];
                    } else {
                        // Without '=', we set the environment variable to the empty string
                        // Note that this is not well supported on Windows
                        define.value = &.{};
                    }
                    try self.defines.append(aa, define);
                } else if (arg.is("-m", "--mode")) {
                    const mode = (args.pop() orelse return error.ExpectedMode);
                    self.mode = if (mode.is("clnt", "client"))
                        Mode.Client
                    else if (mode.is("srvr", "server"))
                        Mode.Server
                    else if (mode.is("ch", "check"))
                        Mode.Check
                    else if (mode.is("test", "test"))
                        Mode.Test
                    else
                        return error.ModeFormatError;
                    std.debug.print("Found mode {}\n", .{self.mode.?});
                } else if (arg.is("--", "--")) {
                    found_dashdash = true;
                } else {
                    // This argument is not recognised
                    handled = false;
                }

                if (handled)
                    continue;
            }

            if (!found_dashdash) {
                try self.extra_before_dashdash.append(aa, arg.arg);
            } else {
                try self.extra_after_dashdash.append(aa, arg.arg);
            }
        }
    }
};

pub const Loader = struct {
    pub const Self = @This();

    config: Config = .{},
    cli_args: CliArgs = .{},

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

    pub fn load(self: *Self, os_args: std.process.Args, log: *rubr.Log) !void {
        self.config = .{};

        log.setLevel(self.config.verbose);

        // We first load CLI arguments:
        // - Set verbose as early as possible
        // - Can in the future be used to specify the config.zon to load
        try self.args.setupFromOS(os_args);
        try self.cli_args.load(self.aa, &self.args);

        if (self.cli_args.verbose) |level|
            log.setLevel(level);

        // Load the config.zon
        {
            var f = self.home;
            try f.add(".config");
            try f.add("syrc");
            try f.add("config.zon");

            if (log.level(1)) |w|
                try rubr.flush.print(w, "Loading config from '{s}' ... ", .{f.path()});

            if (self.loadConfigFromFile(f)) {
                if (log.level(1)) |w|
                    try rubr.flush.print(w, "OK\n", .{});
            } else |err| {
                if (log.level(1)) |w|
                    try rubr.flush.print(w, "Failed {}\n", .{err});
            }
        }

        // Merge CLI arguments into self.config
        self.updateConfigFromCliArgs(log) catch |err|
            try log.err("Failed to parse CLI arguments: {}\n", .{err});

        try self.updateConfigWithDefaults();
    }

    fn loadConfigFromFile(self: *Self, f: rubr.fs.Path) !void {
        if (!f.exists(self.io))
            return error.FileDoesNotExist;

        const content = try f.readSentinel(self.io, self.a);
        defer self.a.free(content);
        self.config = try std.zon.parse.fromSliceAlloc(Config, self.aa, content, null, .{});
    }

    pub fn updateConfigFromCliArgs(self: *Self, log: *rubr.Log) !void {
        const config: *Config = &self.config;
        const cli_args: *CliArgs = &self.cli_args;

        // Free args before '--' are interpreted
        outer: for (cli_args.extra_before_dashdash.items) |extra| {
            if (cli_args.ip == null) {
                for (config.aliases) |alias| {
                    if (std.mem.eql(u8, extra, alias.name)) {
                        cli_args.ip = alias.ip;
                        if (log.level(1)) |w|
                            try rubr.flush.print(w, "\tReplaced IP '{s}' with '{s}'\n", .{ extra, alias.ip });
                        continue :outer;
                    }
                }
            }
            if (std.mem.findScalar(u8, extra, '=')) |ix| {
                if (ix + 1 == extra.len) {
                    try config.defines.append(self.aa, .{ .key = extra[0..ix] });
                } else {
                    try config.defines.append(self.aa, .{ .key = extra[0..ix], .value = extra[ix + 1 ..] });
                }
                continue :outer;
            }

            try config.extra.append(self.aa, extra);
        }

        // Free args after '--' are not interpreted
        for (cli_args.extra_after_dashdash.items) |extra| {
            try config.extra.append(self.aa, extra);
        }

        if (cli_args.name) |name|
            config.name = name;
        if (cli_args.suffix) |suffix|
            config.suffix = suffix;
        if (cli_args.print_help) |print_help|
            config.print_help = print_help;
        if (cli_args.verbose) |verbose|
            config.verbose = verbose;
        if (cli_args.base) |base|
            config.base = base;
        if (cli_args.ip) |ip|
            config.ip = ip;
        if (cli_args.port) |port|
            config.port = port;
        if (cli_args.mode) |mode|
            config.mode = mode;
        if (cli_args.j) |j|
            config.j = j;
        if (cli_args.reset_folder) |reset_folder|
            config.reset_folder = reset_folder;
        if (cli_args.cleanup_folder) |cleanup_folder|
            config.cleanup_folder = cleanup_folder;
        if (cli_args.reset_store) |reset_store|
            config.reset_store = reset_store;
        if (cli_args.collect) |collect|
            config.collect = collect;
        if (cli_args.store_path) |store_path|
            config.store_path = store_path;

        for (cli_args.defines.items) |define|
            try config.defines.append(self.aa, define);
    }

    pub fn updateConfigWithDefaults(self: *Self) !void {
        if (self.config.j == 0)
            self.config.j = std.Thread.getCpuCount() catch 0;

        if (self.config.name.len == 0) {
            if (builtin.os.tag != .windows) {
                var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
                const hostname = try std.posix.gethostname(&buffer);
                self.config.name = try self.aa.dupe(u8, hostname);
            }
        }

        if (!std.fs.path.isAbsolute(self.config.base)) {
            const part = if (self.config.base.len == 0) "." else self.config.base;
            self.config.base = try rubr.fs.cwdPathAlloc(self.io, self.aa, part);
        }

        if (!std.fs.path.isAbsolute(self.config.store_path)) {
            var store_path = self.home;
            try store_path.add(self.config.store_path);
            self.config.store_path = try self.aa.dupe(u8, store_path.path());
        }
    }

    pub fn printHelp(self: Self, w: *std.Io.Writer) !void {
        try w.print("Help for {s}\n", .{self.cli_args.exe_name});
        try w.print("    -h/--help                         Print this help [{}]\n", .{self.config.print_help});
        try w.print("    -v/--verbose         LEVEL        Verbosity level [{}]\n", .{self.config.verbose});
        try w.print("    -j/--jobs            NUMBER       Number of threads to use [{}]\n", .{self.config.j});
        try w.print("    -b/--base            FOLDER       Base folder to use [{s}]\n", .{self.config.base});
        try w.print("    -n/--name            NAME         Name to use [{s}]\n", .{self.config.name});
        try w.print("    -N/--suffix          NAME         Additional name suffix to use [{s}]\n", .{self.config.suffix orelse ""});
        try w.print("    -r/--reset-folder                 Force a reset of the base destination folder [{}]\n", .{self.config.reset_folder});
        try w.print("    -R/--reset-store                  Force a reset of peer's store [{}]\n", .{self.config.reset_store});
        try w.print("    -c/--collect                      Collect the server state back [{}]\n", .{self.config.collect});
        try w.print("    -a/--ip              ADDRESS      Ip address [{s}]\n", .{self.config.ip});
        try w.print("    -p/--port            PORT         Port to use [{}]\n", .{self.config.port});
        try w.print("    -m/--mode            MODE         Operation mode: 'client', 'server', 'check' and 'test' [{}]\n", .{self.config.mode});
        try w.print("    -s/--store           FOLDER       Folder for blob store [{s}]\n", .{self.config.store_path});
        try w.print("    -D/--define          VAR=VALUE    Define/undefine environment variable at remote site. Using 'abc=' will undefine $abc.\n", .{});
        try w.print("Developed by Geert Fannes.\n", .{});
    }
};

const std = @import("std");
const tree = @import("tree.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedString,
    ExpectedSize,
    ExpectedVersion,
    ExpectedRole,
    ExpectedStatus,
    ExpectedFileState,
    ExpectedIX,
    ExpectedCmd,
    ExpectedArg,
    ExpectedFd,
    ExpectedRc,
    UnexpectedData,
    ReasonAlreadySet,
};

pub const My = struct {
    pub const version = 0;
};

pub const Hello = struct {
    const Self = @This();
    pub const Id = 2;
    pub const Role = enum { Client, Server, Broker };
    pub const Status = enum { Ok, Pending, Fail };

    version: u32 = My.version,
    role: Role,
    status: Status,

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Hello");
        defer node.deinit();
        node.attr("version", self.version);
        node.attr("role", self.role);
        node.attr("status", self.status);
    }
    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.version, 3);
        try tw.writeLeaf(@intFromEnum(self.role), 3);
        try tw.writeLeaf(@intFromEnum(self.status), 3);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.version, 3, {}))
            return Error.ExpectedVersion;

        var u: u32 = undefined;

        if (!try tr.readLeaf(&u, 3, {}))
            return Error.ExpectedRole;
        self.role = @enumFromInt(u);

        if (!try tr.readLeaf(&u, 3, {}))
            return Error.ExpectedStatus;
        self.status = @enumFromInt(u);
    }
};

pub const Replicate = struct {
    const Self = @This();
    pub const Id = 4;

    a: std.mem.Allocator,
    base: []const u8 = &.{},
    reset: bool = false,
    cleanup: bool = false,
    files: tree.FileStates = .{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.a.free(self.base);
        for (self.files.items) |*item|
            item.deinit();
        self.files.deinit(self.a);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Replicate");
        defer node.deinit();
        node.attr("base", self.base);
        node.attr("reset", self.reset);
        node.attr("cleanup", self.cleanup);
        for (self.files.items) |item|
            item.write(&node);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.base, 3);
        try tw.writeLeaf(self.reset, 5);
        try tw.writeLeaf(self.cleanup, 7);
        try tw.writeLeaf(self.files.items.len, 9);
        for (self.files.items) |file| {
            try tw.writeComposite(file, 2);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.base, 3, self.a))
            return Error.ExpectedString;

        if (!try tr.readLeaf(&self.reset, 5, {}))
            return Error.ExpectedString;

        if (!try tr.readLeaf(&self.cleanup, 7, {}))
            return Error.ExpectedString;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 9, {}))
            return Error.ExpectedSize;

        var files = tree.FileStates{};
        try files.resize(self.a, size);
        for (files.items) |*file| {
            file.* = tree.FileState.init(self.a);
            if (!try tr.readComposite(file, 2))
                return Error.ExpectedFileState;
        }
        self.files = files;

        if (!try tr.isClose())
            return Error.UnexpectedData;
    }
};

pub const Missing = struct {
    const Self = @This();
    const IXs = std.ArrayList(usize);
    pub const Id = 6;

    a: std.mem.Allocator,
    ixs: IXs = .{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.ixs.deinit(self.a);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Missing");
        defer node.deinit();

        for (self.ixs.items) |ix| {
            var n = node.node("Index");
            defer n.deinit();
            n.attr("ix", ix);
        }
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.ixs.items.len, 3);
        for (self.ixs.items) |ix| {
            try tw.writeLeaf(ix, 5);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 3, {}))
            return Error.ExpectedSize;

        try self.ixs.resize(self.a, size);
        for (self.ixs.items) |*ix| {
            if (!try tr.readLeaf(ix, 5, {}))
                return Error.ExpectedIX;
        }
    }
};

pub const Content = struct {
    const Self = @This();
    const Data = std.ArrayList([]const u8);
    pub const Id = 8;

    a: std.mem.Allocator,
    owning: bool,
    data: Data = .{},

    pub fn init(a: std.mem.Allocator, owning: bool) Self {
        return Self{ .a = a, .owning = owning };
    }
    pub fn deinit(self: *Self) void {
        if (self.owning) {
            for (self.data.items) |str|
                self.a.free(str);
        }
        self.data.deinit(self.a);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Content");
        defer node.deinit();
        for (self.data.items) |str| {
            var n = node.node("Content");
            defer n.deinit();
            n.attr("size", str.len);
        }
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.data.items.len, 3);
        for (self.data.items) |str| {
            try tw.writeLeaf(str, 5);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 3, {}))
            return Error.ExpectedSize;

        try self.data.resize(self.a, size);
        for (self.data.items) |*str| {
            if (!try tr.readLeaf(str, 5, self.a))
                return Error.ExpectedString;
        }
    }
};

pub const Run = struct {
    const Self = @This();
    pub const Id = 12;
    pub const Args = std.ArrayList([]const u8);

    a: std.mem.Allocator,
    cmd: []const u8 = &.{},
    args: Args = .{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        self.a.free(self.cmd);
        for (self.args.items) |arg|
            self.a.free(arg);
        self.args.deinit(self.a);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Run");
        defer node.deinit();
        node.attr("cmd", self.cmd);
        for (self.args.items) |arg|
            node.attr("arg", arg);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.cmd, 3);
        try tw.writeLeaf(self.args.items.len, 5);
        for (self.args.items) |arg|
            try tw.writeLeaf(arg, 7);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.cmd, 3, self.a))
            return Error.ExpectedCmd;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 5, {}))
            return Error.ExpectedSize;

        try self.args.resize(self.a, size);
        for (self.args.items) |*arg| {
            if (!try tr.readLeaf(arg, 7, self.a))
                return Error.ExpectedArg;
        }
    }
};

pub const Output = struct {
    const Self = @This();
    pub const Id = 14;

    a: std.mem.Allocator,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.stdout) |str|
            self.a.free(str);
        if (self.stderr) |str|
            self.a.free(str);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Output");
        defer node.deinit();
        if (self.stdout) |str|
            node.attr("stdout", str);
        if (self.stderr) |str|
            node.attr("stderr", str);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.stdout) |str|
            try tw.writeLeaf(str, 3);
        if (self.stderr) |str|
            try tw.writeLeaf(str, 5);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var str: []const u8 = undefined;
        if (try tr.readLeaf(&str, 3, self.a))
            self.stdout = str;
        if (try tr.readLeaf(&str, 5, self.a))
            self.stderr = str;
    }
};

pub const Done = struct {
    const Self = @This();
    pub const Id = 16;

    exit: ?u32 = null,
    signal: ?u32 = null,
    stop: ?u32 = null,
    unknown: ?u32 = null,

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Done");
        defer node.deinit();
        if (self.exit) |exit|
            node.attr("exit", exit);
        if (self.signal) |signal|
            node.attr("signal", signal);
        if (self.stop) |stop|
            node.attr("stop", stop);
        if (self.unknown) |unknown|
            node.attr("unknown", unknown);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.exit) |exit|
            try tw.writeLeaf(exit, 3);
        if (self.signal) |signal|
            try tw.writeLeaf(signal, 5);
        if (self.stop) |stop|
            try tw.writeLeaf(stop, 7);
        if (self.unknown) |unknown|
            try tw.writeLeaf(unknown, 9);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        var tmp: u32 = undefined;
        if (try tr.readLeaf(&tmp, 3, {}))
            self.exit = tmp;
        if (try tr.readLeaf(&tmp, 5, {}))
            self.signal = tmp;
        if (try tr.readLeaf(&tmp, 7, {}))
            self.stop = tmp;
        if (try tr.readLeaf(&tmp, 9, {}))
            self.unknown = tmp;
    }
};

pub const Bye = struct {
    const Self = @This();
    pub const Id = 18;

    a: std.mem.Allocator,
    reason: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        if (self.reason) |reason|
            self.a.free(reason);
    }

    pub fn setReason(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.reason != null)
            return Error.ReasonAlreadySet;
        self.reason = try std.fmt.allocPrint(self.a, fmt, args);
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        var node = parent.node("prot.Bye");
        defer node.deinit();
        if (self.reason) |reason|
            node.attr("reason", reason);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        if (self.reason) |reason|
            try tw.writeLeaf(reason, 3);
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        self.reason = undefined;
        if (!try tr.readLeaf(&self.reason.?, 3, self.a))
            self.reason = null;
    }
};

pub fn printMessage(obj: anytype, w: *std.Io.Writer) void {
    var node = rubr.naft.Node.init(w);
    defer node.deinit();
    obj.write(&node);
}

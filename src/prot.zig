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
    ExpectedCmd,
    ExpectedArg,
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
    io: std.Io,
    base: []const u8 = &.{},
    files: tree.FileStates = .{},

    pub fn init(a: std.mem.Allocator, io: std.Io) Self {
        return Self{ .a = a, .io = io };
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
        for (self.files.items) |item|
            item.write(&node);
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        try tw.writeLeaf(self.base, 3);
        try tw.writeLeaf(self.files.items.len, 3);
        for (self.files.items) |file| {
            try tw.writeComposite(file, 2);
        }
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        if (!try tr.readLeaf(&self.base, 3, self.a))
            return Error.ExpectedString;

        var size: usize = undefined;
        if (!try tr.readLeaf(&size, 3, {}))
            return Error.ExpectedSize;

        var files = tree.FileStates{};
        try files.resize(self.a, size);
        for (files.items) |*file| {
            file.* = tree.FileState.init(self.a, self.io);
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
    pub const Id = 6;

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;
        var node = parent.node("prot.Missing");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
    }
};

pub const Content = struct {
    const Self = @This();
    pub const Id = 8;

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;
        var node = parent.node("prot.Content");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
    }
};

pub const Ready = struct {
    const Self = @This();
    pub const Id = 10;

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;
        var node = parent.node("prot.Ready");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
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

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;
        var node = parent.node("prot.Output");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
    }
};

pub const Done = struct {
    const Self = @This();
    pub const Id = 16;

    pub fn init() Self {
        return Self{};
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: Self, parent: *rubr.naft.Node) void {
        _ = self;
        var node = parent.node("prot.Done");
        defer node.deinit();
    }

    pub fn writeComposite(self: Self, tw: anytype) !void {
        _ = self;
        _ = tw;
    }
    pub fn readComposite(self: *Self, tr: anytype) !void {
        _ = self;
        _ = tr;
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

pub fn printMessage(obj: anytype, log: *const rubr.log.Log) void {
    if (log.level(1)) |w| {
        var node = rubr.naft.Node.init(w);
        defer node.deinit();
        obj.write(&node);
    }
}

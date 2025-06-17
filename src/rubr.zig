// Output from `rake export[walker,cli,log]` from https://github.com/gfannes/rubr from 2025-06-18

const std = @import("std");

// Export from 'src/walker.zig'
pub const walker = struct {
    // &todo Take `.gitignore` and `.ignore` into account
    
    const Error = error{
        CouldNotReadIgnore,
    };
    
    pub const Offsets = struct {
        base: usize = 0,
        name: usize = 0,
    };
    
    pub const Kind = enum {
        Enter,
        Leave,
        File,
    };
    
    pub const Walker = struct {
        const Ignore = struct { buffer: Buffer = undefined, ignore: ignore.Ignore = undefined, path_len: usize = 0 };
        const IgnoreStack = std.ArrayList(Ignore);
        const Buffer = std.ArrayList(u8);
    
        filter: Filter = .{},
    
        _a: std.mem.Allocator,
    
        // We keep track of the current path as a []const u8. If the caller has to do this,
        // he has to use Dir.realpath() which is less efficient.
        _buffer: [std.fs.max_path_bytes]u8 = undefined,
        _path: []const u8 = &.{},
        _base: usize = undefined,
    
        _ignore_offset: usize = 0,
    
        _ignore_stack: IgnoreStack = undefined,
    
        pub fn init(a: std.mem.Allocator) Walker {
            return Walker{ ._a = a, ._ignore_stack = IgnoreStack.init(a) };
        }
    
        pub fn deinit(self: *Walker) void {
            for (self._ignore_stack.items) |*item| {
                item.ignore.deinit();
                item.buffer.deinit();
            }
            self._ignore_stack.deinit();
        }
    
        pub fn walk(self: *Walker, basedir: std.fs.Dir, cb: anytype) !void {
            self._path = try basedir.realpath(".", &self._buffer);
            self._base = self._path.len + 1;
    
            var dir = try basedir.openDir(".", .{ .iterate = true });
            defer dir.close();
    
            const path = self._path;
    
            try cb.call(dir, path, null, Kind.Enter);
            try self._walk(dir, cb);
            try cb.call(dir, path, null, Kind.Leave);
        }
    
        fn _walk(self: *Walker, dir: std.fs.Dir, cb: anytype) !void {
            var added_ignore = false;
    
            if (dir.openFile(".gitignore", .{})) |file| {
                defer file.close();
    
                const stat = try file.stat();
    
                var ig = Ignore{ .buffer = try Buffer.initCapacity(self._a, stat.size) };
                try ig.buffer.resize(stat.size);
                if (stat.size != try file.readAll(ig.buffer.items))
                    return Error.CouldNotReadIgnore;
    
                ig.ignore = try ignore.Ignore.initFromContent(ig.buffer.items, self._a);
                ig.path_len = self._path.len;
                try self._ignore_stack.append(ig);
    
                self._ignore_offset = ig.path_len + 1;
    
                added_ignore = true;
            } else |_| {}
    
            var it = dir.iterate();
            while (try it.next()) |el| {
                if (!self.filter.call(dir, el))
                    continue;
    
                const orig_path_len = self._path.len;
                defer self._path.len = orig_path_len;
    
                const offsets = Offsets{ .base = self._base, .name = self._path.len + 1 };
                self._append_to_path(el.name);
    
                switch (el.kind) {
                    std.fs.File.Kind.file => {
                        if (slc.last(self._ignore_stack.items)) |e| {
                            const ignore_path = self._path[self._ignore_offset..];
                            if (e.ignore.match(ignore_path))
                                continue;
                        }
    
                        try cb.call(dir, self._path, offsets, Kind.File);
                    },
                    std.fs.File.Kind.directory => {
                        if (slc.last(self._ignore_stack.items)) |e| {
                            const ignore_path = self._path[self._ignore_offset..];
                            if (e.ignore.match(ignore_path))
                                continue;
                        }
    
                        var subdir = try dir.openDir(el.name, .{ .iterate = true });
                        defer subdir.close();
    
                        const path = self._path;
    
                        try cb.call(subdir, path, offsets, Kind.Enter);
    
                        try self._walk(subdir, cb);
    
                        try cb.call(subdir, path, offsets, Kind.Leave);
                    },
                    else => {},
                }
            }
    
            if (added_ignore) {
                if (self._ignore_stack.pop()) |v| {
                    v.buffer.deinit();
                    var v_mut = v;
                    v_mut.ignore.deinit();
                }
    
                self._ignore_offset = if (slc.last(self._ignore_stack.items)) |x| x.path_len + 1 else 0;
            }
        }
    
        fn _append_to_path(self: *Walker, name: []const u8) void {
            self._buffer[self._path.len] = '/';
            self._path.len += 1;
    
            std.mem.copyForwards(u8, self._buffer[self._path.len..], name);
            self._path.len += name.len;
        }
    };
    
    pub const Filter = struct {
        // Skip hidden files by default
        hidden: bool = true,
    
        // Skip files with following extensions. Include '.' in extension.
        extensions: []const []const u8 = &.{},
    
        fn call(self: Filter, _: std.fs.Dir, entry: std.fs.Dir.Entry) bool {
            if (self.hidden and is_hidden(entry.name))
                return false;
    
            const my_ext = std.fs.path.extension(entry.name);
            for (self.extensions) |ext| {
                if (std.mem.eql(u8, my_ext, ext))
                    return false;
            }
    
            return true;
        }
    };
    
    fn is_hidden(name: []const u8) bool {
        return name.len > 0 and name[0] == '.';
    }
    

    // Export from 'src/walker/ignore.zig'
    pub const ignore = struct {
        pub const Ignore = struct {
            const Self = @This();
            const Globs = std.ArrayList(glb.Glob);
            const Strings = std.ArrayList([]const u8);
        
            globs: Globs,
            antiglobs: Globs,
        
            pub fn init(ma: std.mem.Allocator) Ignore {
                return Ignore{ .globs = Globs.init(ma), .antiglobs = Globs.init(ma) };
            }
        
            pub fn deinit(self: *Self) void {
                for ([_]*Globs{ &self.globs, &self.antiglobs }) |globs| {
                    for (globs.items) |*item|
                        item.deinit();
                    globs.deinit();
                }
            }
        
            pub fn initFromFile(dir: std.fs.Dir, name: []const u8, ma: std.mem.Allocator) !Self {
                const file = try dir.openFile(name, .{});
                defer file.close();
        
                const stat = try file.stat();
        
                const r = file.reader();
        
                const content = try r.readAllAlloc(ma, stat.size);
                defer ma.free(content);
        
                return initFromContent(content, ma);
            }
        
            pub fn initFromContent(content: []const u8, ma: std.mem.Allocator) !Self {
                var self = Self.init(ma);
                errdefer self.deinit();
        
                var strange_content = strng.Strange{ .content = content };
                while (strange_content.popLine()) |line| {
                    var strange_line = strng.Strange{ .content = line };
        
                    // Trim
                    _ = strange_line.popMany(' ');
                    _ = strange_line.popManyBack(' ');
        
                    if (strange_line.popMany('#') > 0)
                        // Skip comments
                        continue;
        
                    if (strange_line.empty())
                        continue;
        
                    const is_anti = strange_line.popMany('!') > 0;
                    const globs = if (is_anti) &self.antiglobs else &self.globs;
        
                    // '*.txt'    ignores '**/*.txt'
                    // 'dir/'     ignores '**/dir/**'
                    // '/dir/'    ignores 'dir/**'
                    // 'test.txt' ignores '**/test.txt'
                    var config = glb.Config{};
                    if (strange_line.popMany('/') == 0)
                        config.front = "**";
                    config.pattern = strange_line.str();
                    if (strange_line.back() == '/')
                        config.back = "**";
        
                    try globs.append(try glb.Glob.init(config, ma));
                }
        
                return self;
            }
        
            pub fn addExt(self: *Ignore, ext: []const u8) !void {
                const buffer: [128]u8 = undefined;
                const fba = std.heap.FixedBufferAllocator.init(buffer);
                const my_ext = try std.mem.concat(fba, u8, &[_][]const u8{ ".", ext });
        
                const glob_config = glb.Config{ .pattern = my_ext, .front = "**" };
                try self.globs.append(try glb.Glob.init(glob_config, self.globs.allocator));
            }
        
            pub fn match(self: Self, fp: []const u8) bool {
                var ret = false;
                for (self.globs.items) |item| {
                    if (item.match(fp))
                        ret = true;
                }
                for (self.antiglobs.items) |item| {
                    if (item.match(fp))
                        ret = false;
                }
                return ret;
            }
        };
        
    };
};

// Export from 'src/slc.zig'
pub const slc = struct {
    pub fn is_empty(slice: anytype) bool {
        return slice.len == 0;
    }
    
    pub fn first(slice: anytype) ?@TypeOf(slice[0]) {
        return if (slice.len > 0) slice[0] else null;
    }
    pub fn firstPtr(slice: anytype) ?@TypeOf(&slice[0]) {
        return if (slice.len > 0) &slice[0] else null;
    }
    pub fn firstPtrUnsafe(slice: anytype) @TypeOf(&slice[0]) {
        return &slice[0];
    }
    
    pub fn last(slice: anytype) ?@TypeOf(slice[0]) {
        return if (slice.len > 0) slice[slice.len - 1] else null;
    }
    pub fn lastPtr(slice: anytype) ?@TypeOf(&slice[0]) {
        return if (slice.len > 0) &slice[slice.len - 1] else null;
    }
    pub fn lastPtrUnsafe(slice: anytype) @TypeOf(&slice[0]) {
        return &slice[slice.len - 1];
    }
    
};

// Export from 'src/strng.zig'
pub const strng = struct {
    // &todo Support avoiding escaping with balanced brackets
    // &todo Implement escaping
    // &todo Support creating file/folder tree for UTs (mod+cli)
    // &todo Create spec
    // - Support for post-body attributes?
    
    pub const Strange = struct {
        const Self = @This();
    
        content: []const u8,
    
        pub fn empty(self: Self) bool {
            return self.content.len == 0;
        }
        pub fn size(self: Self) usize {
            return self.content.len;
        }
    
        pub fn str(self: Self) []const u8 {
            return self.content;
        }
    
        pub fn front(self: Self) ?u8 {
            if (self.content.len == 0)
                return null;
            return self.content[0];
        }
        pub fn back(self: Self) ?u8 {
            if (self.content.len == 0)
                return null;
            return self.content[self.content.len - 1];
        }
    
        pub fn popAll(self: *Self) ?[]const u8 {
            if (self.empty())
                return null;
            defer self.content = &.{};
            return self.content;
        }
    
        pub fn popMany(self: *Self, ch: u8) usize {
            for (self.content, 0..) |act, ix| {
                if (act != ch) {
                    self._popFront(ix);
                    return ix;
                }
            }
            defer self.content = &.{};
            return self.content.len;
        }
        pub fn popManyBack(self: *Self, ch: u8) usize {
            var count: usize = 0;
            while (self.content.len > 0 and self.content[self.content.len - 1] == ch) {
                self.content.len -= 1;
                count += 1;
            }
            return count;
        }
    
        pub fn popTo(self: *Self, ch: u8) ?[]const u8 {
            if (std.mem.indexOfScalar(u8, self.content, ch)) |ix| {
                defer self._popFront(ix + 1);
                return self.content[0..ix];
            } else {
                return null;
            }
        }
    
        pub fn popChar(self: *Self, ch: u8) bool {
            if (self.content.len > 0 and self.content[0] == ch) {
                self._popFront(1);
                return true;
            }
            return false;
        }
        pub fn popCharBack(self: *Self, ch: u8) bool {
            if (self.content.len > 0 and self.content[self.content.len - 1] == ch) {
                self._popBack(1);
                return true;
            }
            return false;
        }
    
        pub fn popOne(self: *Self) ?u8 {
            if (self.content.len > 0) {
                defer self._popFront(1);
                return self.content[0];
            }
            return null;
        }
    
        pub fn popStr(self: *Self, s: []const u8) bool {
            if (std.mem.startsWith(u8, self.content, s)) {
                self._popFront(s.len);
                return true;
            }
            return false;
        }
    
        pub fn popLine(self: *Self) ?[]const u8 {
            if (self.empty())
                return null;
    
            var line = self.content;
            if (std.mem.indexOfScalar(u8, self.content, '\n')) |ix| {
                line.len = if (ix > 0 and self.content[ix - 1] == '\r') ix - 1 else ix;
                self._popFront(ix + 1);
            } else {
                self.content = &.{};
            }
    
            return line;
        }
    
        pub fn popInt(self: *Self, T: type) ?T {
            // Find number of chars comprising number
            var slice = self.content;
            for (self.content, 0..) |ch, ix| {
                switch (ch) {
                    '0'...'9', '-', '+' => {},
                    else => {
                        slice.len = ix;
                        break;
                    },
                }
            }
            if (std.fmt.parseInt(T, slice, 10) catch null) |v| {
                self._popFront(slice.len);
                return v;
            }
            return null;
        }
    
        fn _popFront(self: *Self, count: usize) void {
            self.content.ptr += count;
            self.content.len -= count;
        }
        fn _popBack(self: *Self, count: usize) void {
            self.content.len -= count;
        }
    };
    
};

// Export from 'src/glb.zig'
pub const glb = struct {
    // &todo Support '?' pattern
    
    const Error = error{
        EmptyPattern,
        IllegalWildcard,
    };
    
    const Wildcard = enum {
        None,
        Some, // '*': All characters except path separator '/'
        All, // '**': All characters
    
        pub fn fromStr(str: []const u8) !Wildcard {
            if (str.len == 0)
                return Wildcard.None;
            if (std.mem.eql(u8, str, "*"))
                return Wildcard.Some;
            if (std.mem.eql(u8, str, "**"))
                return Wildcard.All;
            return Error.IllegalWildcard;
        }
    
        pub fn max(a: Wildcard, b: Wildcard) Wildcard {
            return switch (a) {
                Wildcard.None => b,
                Wildcard.Some => if (b == Wildcard.None) a else b,
                Wildcard.All => a,
            };
        }
    };
    
    // A Part is easy to match: search for str and check if whatever in-between matches with wildcard
    const Part = struct {
        wildcard: Wildcard,
        str: []const u8,
    };
    
    pub const Config = struct {
        pattern: []const u8 = &.{},
        front: []const u8 = &.{},
        back: []const u8 = &.{},
    };
    
    pub const Glob = struct {
        const Self = @This();
        const Parts = std.ArrayList(Part);
    
        ma: std.mem.Allocator,
        parts: Parts,
        config: ?*Config = null,
    
        pub fn init(config: Config, ma: std.mem.Allocator) !Glob {
            // Create our own copy of config to unsure it outlives self
            const my_config = try ma.create(Config);
            my_config.pattern = try ma.dupe(u8, config.pattern);
            my_config.front = try ma.dupe(u8, config.front);
            my_config.back = try ma.dupe(u8, config.back);
    
            var ret = try initUnmanaged(my_config.*, ma);
            ret.config = my_config;
    
            return ret;
        }
    
        // Assumes config outlives self
        pub fn initUnmanaged(config: Config, ma: std.mem.Allocator) !Glob {
            if (config.pattern.len == 0)
                return Error.EmptyPattern;
    
            var glob = Glob{ .ma = ma, .parts = Parts.init(ma) };
    
            var strange = strng.Strange{ .content = config.pattern };
    
            var wildcard = try Wildcard.fromStr(config.front);
    
            while (true) {
                if (strange.popTo('*')) |str| {
                    if (str.len > 0) {
                        try glob.parts.append(Part{ .wildcard = wildcard, .str = str });
                    }
    
                    // We found a single '*', check for more '*' to decide if we can match path separators as well
                    {
                        const new_wildcard = if (strange.popMany('*') > 0) Wildcard.All else Wildcard.Some;
    
                        if (str.len == 0) {
                            // When pattern starts with a '*', keep the config.front wildcard if it is stronger
                            wildcard = Wildcard.max(wildcard, new_wildcard);
                        } else {
                            wildcard = new_wildcard;
                        }
                    }
    
                    if (strange.empty()) {
                        // We popped everything from strange and will hence not enter below's branch: setup wildcard according to config.back
                        const new_wildcard = try Wildcard.fromStr(config.back);
                        wildcard = Wildcard.max(wildcard, new_wildcard);
                    }
                } else if (strange.popAll()) |str| {
                    try glob.parts.append(Part{ .wildcard = wildcard, .str = str });
    
                    wildcard = try Wildcard.fromStr(config.back);
                } else {
                    try glob.parts.append(Part{ .wildcard = wildcard, .str = "" });
                    break;
                }
            }
    
            return glob;
        }
    
        pub fn deinit(self: *Self) void {
            self.parts.deinit();
            if (self.config) |el| {
                self.ma.free(el.pattern);
                self.ma.free(el.front);
                self.ma.free(el.back);
                self.ma.destroy(el);
            }
        }
    
        pub fn match(self: Self, haystack: []const u8) bool {
            return _match(self.parts.items, haystack);
        }
    
        fn _match(parts: []const Part, haystack: []const u8) bool {
            if (parts.len == 0)
                return true;
    
            const part = &parts[0];
    
            switch (part.wildcard) {
                Wildcard.None => {
                    if (part.str.len == 0) {
                        // This is a special case with an empty part.str: this should only for the last part
                        std.debug.assert(parts.len == 1);
    
                        // None only matches if we are at the end
                        return haystack.len == 0;
                    }
    
                    if (!std.mem.startsWith(u8, haystack, part.str))
                        return false;
    
                    return _match(parts[1..], haystack[part.str.len..]);
                },
                Wildcard.Some => {
                    if (part.str.len == 0) {
                        // This is a special case with an empty part.str: this should only for the last part
                        std.debug.assert(parts.len == 1);
    
                        // Accept a full match if there is no path separator
                        return std.mem.indexOfScalar(u8, haystack, '/') == null;
                    } else {
                        var start: usize = 0;
                        while (start < haystack.len) {
                            if (std.mem.indexOf(u8, haystack[start..], part.str)) |ix| {
                                if (std.mem.indexOfScalar(u8, haystack[start .. start + ix], '/')) |_|
                                    // We found a path separator: this is not a match
                                    return false;
                                if (_match(parts[1..], haystack[start + ix + part.str.len ..]))
                                    // We found a match for the other parts
                                    return true;
                                // No match found downstream: try to match part.str further in haystack
                                start += ix + 1;
                            }
                            break;
                        }
                    }
                    return false;
                },
                Wildcard.All => {
                    if (part.str.len == 0) {
                        // This is a special case with an empty part.str: this should only be used for the last part
                        std.debug.assert(parts.len == 1);
    
                        // Accept a full match until the end if this is the last part.
                        // If this is not the last part, something unexpected happened: Glob.init() should not produce something like that
                        return parts.len == 1;
                    } else {
                        var start: usize = 0;
                        while (start < haystack.len) {
                            if (std.mem.indexOf(u8, haystack[start..], part.str)) |ix| {
                                if (_match(parts[1..], haystack[start + ix + part.str.len ..]))
                                    // We found a match for the other parts
                                    return true;
                                // No match found downstream: try to match part.str further in haystack
                                start += ix + 1;
                            }
                            break;
                        }
                    }
                    return false;
                },
            }
        }
    };
    
};

// Export from 'src/cli.zig'
pub const cli = struct {
    pub const Args = struct {
        const Self = @This();
    
        argv: [][]const u8 = &.{},
        aa: std.heap.ArenaAllocator,
    
        pub fn init(a: std.mem.Allocator) Self {
            return Self{ .aa = std.heap.ArenaAllocator.init(a) };
        }
        pub fn deinit(self: *Self) void {
            self.aa.deinit();
        }
    
        pub fn setupFromOS(self: *Self) !void {
            const aaa = self.aa.allocator();
    
            const os_argv = try std.process.argsAlloc(aaa);
            defer std.process.argsFree(aaa, os_argv);
    
            self.argv = try aaa.alloc([]const u8, os_argv.len);
    
            for (os_argv, 0..) |str, ix| {
                self.argv[ix] = try aaa.dupe(u8, str);
            }
        }
        pub fn setupFromData(self: *Self, argv: []const []const u8) !void {
            const aaa = self.aa.allocator();
    
            self.argv = try aaa.alloc([]const u8, argv.len);
            for (argv, 0..) |slice, ix| {
                self.argv[ix] = try aaa.dupe(u8, slice);
            }
        }
    
        pub fn pop(self: *Self) ?Arg {
            if (self.argv.len == 0) return null;
    
            const aaa = self.aa.allocator();
            const arg = aaa.dupe(u8, std.mem.sliceTo(self.argv[0], 0)) catch return null;
            self.argv.ptr += 1;
            self.argv.len -= 1;
    
            return Arg{ .arg = arg };
        }
    };
    
    pub const Arg = struct {
        const Self = @This();
    
        arg: []const u8,
    
        pub fn is(self: Arg, sh: []const u8, lh: []const u8) bool {
            return std.mem.eql(u8, self.arg, sh) or std.mem.eql(u8, self.arg, lh);
        }
    
        pub fn as(self: Self, T: type) !T {
            return try std.fmt.parseInt(T, self.arg, 10);
        }
    };
    
};

// Export from 'src/log.zig'
pub const log = struct {
    // &improv: Support both buffered and non-buffered logging
    pub const Log = struct {
        const Self = @This();
        const BufferedWriter = std.io.BufferedWriter(4096, std.fs.File.Writer);
        // const Writer = BufferedWriter.Writer;
        pub const Writer = std.fs.File.Writer;
    
        _file: std.fs.File = std.io.getStdOut(),
        _do_close: bool = false,
        _buffered_writer: BufferedWriter = undefined,
        _writer: Writer = undefined,
        _lvl: usize = 0,
    
        pub fn init(self: *Self) void {
            self.initWriter();
        }
        pub fn deinit(self: *Self) void {
            self.closeWriter() catch {};
        }
    
        pub fn toFile(self: *Self, filepath: []const u8) !void {
            try self.closeWriter();
    
            if (std.fs.path.isAbsolute(filepath))
                self._file = try std.fs.createFileAbsolute(filepath, .{})
            else
                self._file = try std.fs.cwd().createFile(filepath, .{});
            self._do_close = true;
    
            self.initWriter();
        }
    
        pub fn setLevel(self: *Self, lvl: usize) void {
            self._lvl = lvl;
        }
    
        pub fn writer(self: Self) Writer {
            return self._writer;
        }
    
        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print(fmt, args);
        }
        pub fn info(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Info: " ++ fmt, args);
        }
        pub fn warning(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Warning: " ++ fmt, args);
        }
        pub fn err(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Error: " ++ fmt, args);
        }
    
        pub fn level(self: Self, lvl: usize) ?Writer {
            if (self._lvl >= lvl)
                return self._writer;
            return null;
        }
    
        fn initWriter(self: *Self) void {
            self._writer = self._file.writer();
            // self.buffered_writer = std.io.bufferedWriter(self.file.writer());
            // self.writer = self.buffered_writer.writer();
        }
        fn closeWriter(self: *Self) !void {
            // try self.buffered_writer.flush();
            if (self._do_close) {
                self._file.close();
                self._do_close = false;
            }
        }
    };
    
};

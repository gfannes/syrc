// Output from `rake export[walker,cli,log,profile,naft,util,comm,pipe]` from https://github.com/gfannes/rubr from 2025-11-03

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
    
        a: std.mem.Allocator,
    
        // We keep track of the current path as a []const u8. If the caller has to do this,
        // he has to use Dir.realpath() which is less efficient.
        buffer: [std.fs.max_path_bytes]u8 = undefined,
        path: []const u8 = &.{},
        base: usize = undefined,
    
        ignore_offset: usize = 0,
    
        ignore_stack: IgnoreStack = .{},
    
        pub fn init(a: std.mem.Allocator) Walker {
            return Walker{ .a = a };
        }
    
        pub fn deinit(self: *Walker) void {
            for (self.ignore_stack.items) |*item| {
                item.ignore.deinit();
                item.buffer.deinit(self.a);
            }
            self.ignore_stack.deinit(self.a);
        }
    
        // cb() is passed:
        // - dir: std.fs.Dir
        // - path: full path of file/folder
        // - offsets: optional offsets for basename and filename. Only for the toplevel Enter/Leave is this null to avoid out of bound reading
        // - kind: Enter/Leave/File
        pub fn walk(self: *Walker, basedir: std.fs.Dir, cb: anytype) !void {
            self.path = try basedir.realpath(".", &self.buffer);
            self.base = self.path.len + 1;
    
            var dir = try basedir.openDir(".", .{ .iterate = true });
            defer dir.close();
    
            const path = self.path;
    
            try cb.call(dir, path, null, Kind.Enter);
            try self._walk(dir, cb);
            try cb.call(dir, path, null, Kind.Leave);
        }
    
        fn _walk(self: *Walker, dir: std.fs.Dir, cb: anytype) !void {
            var added_ignore = false;
    
            if (dir.openFile(".gitignore", .{})) |file| {
                defer file.close();
    
                const stat = try file.stat();
    
                var ig = Ignore{ .buffer = try Buffer.initCapacity(self.a, stat.size) };
                try ig.buffer.resize(self.a, stat.size);
                if (stat.size != try file.readAll(ig.buffer.items))
                    return Error.CouldNotReadIgnore;
    
                ig.ignore = try ignore.Ignore.initFromContent(ig.buffer.items, self.a);
                ig.path_len = self.path.len;
                try self.ignore_stack.append(self.a, ig);
    
                self.ignore_offset = ig.path_len + 1;
    
                added_ignore = true;
            } else |_| {}
    
            var it = dir.iterate();
            while (try it.next()) |el| {
                if (!self.filter.call(dir, el))
                    continue;
    
                const orig_path_len = self.path.len;
                defer self.path.len = orig_path_len;
    
                const offsets = Offsets{ .base = self.base, .name = self.path.len + 1 };
                self._append_to_path(el.name);
    
                switch (el.kind) {
                    std.fs.File.Kind.file => {
                        if (slc.last(self.ignore_stack.items)) |e| {
                            const ignore_path = self.path[self.ignore_offset..];
                            if (e.ignore.match(ignore_path))
                                continue;
                        }
    
                        try cb.call(dir, self.path, offsets, Kind.File);
                    },
                    std.fs.File.Kind.directory => {
                        if (slc.last(self.ignore_stack.items)) |e| {
                            const ignore_path = self.path[self.ignore_offset..];
                            if (e.ignore.match(ignore_path))
                                continue;
                        }
    
                        var subdir = try dir.openDir(el.name, .{ .iterate = true });
                        defer subdir.close();
    
                        const path = self.path;
    
                        try cb.call(subdir, path, offsets, Kind.Enter);
    
                        try self._walk(subdir, cb);
    
                        try cb.call(subdir, path, offsets, Kind.Leave);
                    },
                    else => {},
                }
            }
    
            if (added_ignore) {
                if (self.ignore_stack.pop()) |v| {
                    var v_mut = v;
                    v_mut.buffer.deinit(self.a);
                    v_mut.ignore.deinit();
                }
    
                self.ignore_offset = if (slc.last(self.ignore_stack.items)) |x| x.path_len + 1 else 0;
            }
        }
    
        fn _append_to_path(self: *Walker, name: []const u8) void {
            self.buffer[self.path.len] = '/';
            self.path.len += 1;
    
            std.mem.copyForwards(u8, self.buffer[self.path.len..], name);
            self.path.len += name.len;
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
        
            a: std.mem.Allocator,
            globs: Globs = .{},
            antiglobs: Globs = .{},
        
            pub fn init(a: std.mem.Allocator) Ignore {
                return Ignore{ .a = a };
            }
        
            pub fn deinit(self: *Self) void {
                for ([_]*Globs{ &self.globs, &self.antiglobs }) |globs| {
                    for (globs.items) |*item|
                        item.deinit();
                    globs.deinit(self.a);
                }
            }
        
            pub fn initFromFile(dir: std.fs.Dir, name: []const u8, a: std.mem.Allocator) !Self {
                const file = try dir.openFile(name, .{});
                defer file.close();
        
                const stat = try file.stat();
        
                const r = file.reader();
        
                const content = try r.readAllAlloc(a, stat.size);
                defer a.free(content);
        
                return initFromContent(content, a);
            }
        
            pub fn initFromContent(content: []const u8, a: std.mem.Allocator) !Self {
                var self = Self.init(a);
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
        
                    try globs.append(a, try glb.Glob.init(config, a));
                }
        
                return self;
            }
        
            pub fn addExt(self: *Ignore, ext: []const u8) !void {
                const buffer: [128]u8 = undefined;
                const fba = std.heap.FixedBufferAllocator.init(buffer);
                const my_ext = try std.mem.concat(fba, u8, &[_][]const u8{ ".", ext });
        
                const glob_config = glb.Config{ .pattern = my_ext, .front = "**" };
                try self.globs.append(self.a, try glb.Glob.init(glob_config, self.globs.allocator));
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
    
        a: std.mem.Allocator,
        parts: Parts = .{},
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
        pub fn initUnmanaged(config: Config, a: std.mem.Allocator) !Glob {
            if (config.pattern.len == 0)
                return Error.EmptyPattern;
    
            var glob = Glob{ .a = a };
    
            var strange = strng.Strange{ .content = config.pattern };
    
            var wildcard = try Wildcard.fromStr(config.front);
    
            while (true) {
                if (strange.popTo('*')) |str| {
                    if (str.len > 0) {
                        try glob.parts.append(a, Part{ .wildcard = wildcard, .str = str });
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
                    try glob.parts.append(a, Part{ .wildcard = wildcard, .str = str });
    
                    wildcard = try Wildcard.fromStr(config.back);
                } else {
                    try glob.parts.append(a, Part{ .wildcard = wildcard, .str = "" });
                    break;
                }
            }
    
            return glob;
        }
    
        pub fn deinit(self: *Self) void {
            self.parts.deinit(self.a);
            if (self.config) |el| {
                self.a.free(el.pattern);
                self.a.free(el.front);
                self.a.free(el.back);
                self.a.destroy(el);
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
    pub const Error = error{FilePathTooLong};
    
    // &improv: Support both buffered and non-buffered logging
    pub const Log = struct {
        const Self = @This();
        const Autoclean = struct {
            buffer: [std.fs.max_path_bytes]u8 = undefined,
            filepath: []const u8 = &.{},
        };
    
        _do_close: bool = false,
        _file: std.fs.File = std.fs.File.stdout(),
    
        _buffer: [1024]u8 = undefined,
        _writer: std.fs.File.Writer = undefined,
    
        _io: *std.Io.Writer = undefined,
    
        _lvl: usize = 0,
    
        _autoclean: ?Autoclean = null,
    
        pub fn init(self: *Self) void {
            self.initWriter();
        }
        pub fn deinit(self: *Self) void {
            std.debug.print("Log.deinit()\n", .{});
            self.closeWriter() catch {};
            if (self._autoclean) |autoclean| {
                std.debug.print("Removing '{s}'\n", .{autoclean.filepath});
                std.fs.deleteFileAbsolute(autoclean.filepath) catch {};
            }
        }
    
        // Any '%' in 'filepath' will be replaced with the process id
        const Options = struct {
            autoclean: bool = false,
        };
        pub fn toFile(self: *Self, filepath: []const u8, options: Options) !void {
            try self.closeWriter();
    
            var pct_count: usize = 0;
            for (filepath) |ch| {
                if (ch == '%')
                    pct_count += 1;
            }
    
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const filepath_clean = if (pct_count > 0) blk: {
                var pid_buf: [32]u8 = undefined;
                const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{std.c.getpid()});
                if (filepath.len + pct_count * pid_str.len >= buf.len)
                    return Error.FilePathTooLong;
                var ix: usize = 0;
                for (filepath) |ch| {
                    if (ch == '%') {
                        for (pid_str) |c| {
                            buf[ix] = c;
                            ix += 1;
                        }
                    } else {
                        buf[ix] = ch;
                        ix += 1;
                    }
                }
                break :blk buf[0..ix];
            } else blk: {
                break :blk filepath;
            };
    
            if (std.fs.path.isAbsolute(filepath_clean)) {
                self._file = try std.fs.createFileAbsolute(filepath_clean, .{});
                if (options.autoclean) {
                    self._autoclean = undefined;
                    const fp = self._autoclean.?.buffer[0..filepath_clean.len];
                    std.mem.copyForwards(u8, fp, filepath_clean);
                    if (self._autoclean) |*autoclean| {
                        autoclean.filepath = fp;
                        std.debug.print("Setup autoclean for '{s}'\n", .{autoclean.filepath});
                    }
                }
            } else {
                self._file = try std.fs.cwd().createFile(filepath_clean, .{});
            }
            self._do_close = true;
    
            self.initWriter();
        }
    
        pub fn setLevel(self: *Self, lvl: usize) void {
            self._lvl = lvl;
        }
    
        pub fn writer(self: Self) *std.Io.Writer {
            return self._io;
        }
    
        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._io.print(fmt, args);
            try self._io.flush();
        }
        pub fn info(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self.print("Info: " ++ fmt, args);
        }
        pub fn warning(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self.print("Warning: " ++ fmt, args);
        }
        pub fn err(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self.print("Error: " ++ fmt, args);
        }
    
        pub fn level(self: Self, lvl: usize) ?*std.Io.Writer {
            if (self._lvl >= lvl)
                return self._io;
            return null;
        }
    
        fn initWriter(self: *Self) void {
            self._writer = self._file.writer(&self._buffer);
            self._io = &self._writer.interface;
        }
        fn closeWriter(self: *Self) !void {
            try self._io.flush();
            if (self._do_close) {
                self._file.close();
                self._do_close = false;
            }
        }
    };
    
};

// Export from 'src/profile.zig'
pub const profile = struct {
    pub const Id = enum {
        A,
        B,
        C,
    };
    
    const Timestamp = i128;
    
    const Measurement = struct {
        max: Timestamp = 0,
    };
    
    const count = @typeInfo(Id).@"enum".fields.len;
    var measurements = [_]Measurement{Measurement{}} ** count;
    
    pub const Scope = struct {
        const Self = @This();
    
        id: Id,
        start: Timestamp,
    
        pub fn init(id: Id) Scope {
            return Scope{ .id = id, .start = Self.now() };
        }
        pub fn deinit(self: Self) void {
            const elapse = now() - self.start;
            measurements[@intFromEnum(self.id)].max = elapse;
            const a = @divFloor(elapse, 1_000_000_000);
            const b = elapse - a * 1_000_000_000;
            std.debug.print("elapse: {}.{:0>9.9}s\n", .{ a, @as(u64, @intCast(b)) });
        }
    
        fn now() Timestamp {
            return std.time.nanoTimestamp();
        }
    };
    
};

// Export from 'src/naft.zig'
pub const naft = struct {
    const Error = error{
        CouldNotCreateStdOut,
    };
    
    pub const Node = struct {
        const Self = @This();
    
        io: ?*std.Io.Writer,
        level: usize,
        // Indicates if this Node already contains nested elements (Text, Node). This is used to add a closing '}' upon deinit().
        has_block: bool = false,
        // Indicates if this Node already contains a Node. This is used for deciding newlines etc.
        has_node: bool = false,
    
        pub fn init(io: ?*std.Io.Writer) Node {
            return Node{ .io = io, .level = 0, .has_block = true, .has_node = true };
        }
        pub fn deinit(self: Self) void {
            if (self.level == 0)
                // The top-level block does not need any handling
                return;
    
            if (self.has_block) {
                if (self.has_node)
                    self.indent();
                self.print("}}\n", .{});
            } else {
                self.print("\n", .{});
            }
        }
    
        pub fn node(self: *Self, name: []const u8) Node {
            self.ensure_block(true);
            const n = Node{ .io = self.io, .level = self.level + 1 };
            n.indent();
            n.print("[{s}]", .{name});
            return n;
        }
    
        pub fn attr(self: *Self, key: []const u8, value: anytype) void {
            const T = @TypeOf(value);
    
            if (self.has_block) {
                std.debug.print("Attributes are not allowed anymore: block was already started\n", .{});
                return;
            }
    
            const str = switch (@typeInfo(T)) {
                // We assume that any .pointer can be printed as a string
                .pointer => "s",
                .@"struct" => if (@hasDecl(T, "format")) "f" else "any",
                else => "any",
            };
    
            self.print("({s}:{" ++ str ++ "})", .{ key, value });
        }
        pub fn attr1(self: *Self, value: anytype) void {
            if (self.has_block) {
                std.debug.print("Attributes are not allowed anymore: block was already started\n", .{});
                return;
            }
    
            const str = switch (@typeInfo(@TypeOf(value))) {
                // We assume that any .pointer can be printed as a string
                .pointer => "s",
                else => "any",
            };
    
            self.print("({" ++ str ++ "})", .{value});
        }
    
        pub fn text(self: *Self, str: []const u8) void {
            self.ensure_block(false);
            self.print("{s}", .{str});
        }
    
        fn ensure_block(self: *Self, is_node: bool) void {
            if (!self.has_block)
                self.print("{{", .{});
            self.has_block = true;
            if (is_node) {
                if (!self.has_node)
                    self.print("\n", .{});
                self.has_node = is_node;
            }
        }
    
        fn indent(self: Self) void {
            if (self.level > 1)
                for (0..self.level - 1) |_|
                    self.print("  ", .{});
        }
    
        fn print(self: Self, comptime fmt: []const u8, args: anytype) void {
            if (self.io) |io| {
                io.print(fmt, args) catch {};
                io.flush() catch {};
            } else {
                std.debug.print(fmt, args);
            }
        }
    };
    
};

// Export from 'src/util.zig'
pub const util = struct {
    pub fn baseType(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .pointer => |p| baseType(p.child), // covers *T, []T, [*]T, [*c]T
            .array => |a| baseType(a.child), // [N]T
            .optional => |o| baseType(o.child), // ?T
            .vector => |v| baseType(v.child), // @Vector(N, T)
            else => T,
        };
    }
    
    pub fn baseTypeOf(v: anytype) type {
        return baseType(@TypeOf(v));
    }
    
    pub fn isUIntType(T: type) ?u16 {
        return switch (@typeInfo(T)) {
            .int => |info| if (info.signedness == std.builtin.Signedness.unsigned) info.bits else null,
            else => null,
        };
    }
    
    pub fn isIntType(T: type) ?u16 {
        return switch (@typeInfo(T)) {
            .int => |info| if (info.signedness == std.builtin.Signedness.signed) info.bits else null,
            else => null,
        };
    }
    
    pub fn isStringType(T: type) bool {
        const BaseT = baseType(T);
        if (BaseT != u8)
            return false;
        return switch (@typeInfo(T)) {
            .pointer => true, // covers *T, []T, [*]T, [*c]T
            .array => true, // [N]T
            else => false,
        };
    }
    pub fn isString(str: anytype) bool {
        const Str = @TypeOf(str);
        return isStringType(Str);
    }
    
    pub fn isEven(v: anytype) bool {
        return v % 2 == 0;
    }
    pub fn isOdd(v: anytype) bool {
        return v % 2 == 1;
    }
    
    pub fn arrayLenOf(T: type) usize {
        return switch (@typeInfo(T)) {
            .array => |a| a.len,
            else => @compileError("Expected T to be an array"),
        };
    }
    
};

// Export from 'src/comm.zig'
pub const comm = struct {
    // &todo: Replace id arg for read/write funcs with comptime and check for its even/oddness
    
    // sw: SimpleWriter
    // - sw.writeAll()
    // sr: SimpleReader
    // - sr.readAll()
    // tw: TreeWriter
    // - tw.writeLeaf()
    // - tw.writeComposite()
    // tr: TreeReader
    // - tw.readLeaf()
    // - tw.readComposite()
    
    pub const Error = error{
        TooLarge,
        ExpectedId,
    };
    
    // An Id identifies the type/field that is being sedes within some parent context
    // 0/1 are reserved for internal use
    // Composites must be even, Leafs must be odd
    pub const Id = usize;
    pub const stop = 0;
    pub const close = 1;
    pub fn isLeaf(id: Id) bool {
        return util.isOdd(id) and id >= 3;
    }
    pub fn isComposite(id: Id) bool {
        return util.isEven(id) and id >= 2;
    }
    
    pub const TreeWriter = struct {
        const Self = @This();
    
        out: *std.Io.Writer,
    
        pub fn writeLeaf(self: Self, obj: anytype, id: Id) !void {
            const T = @TypeOf(obj);
            if (comptime util.isStringType(T)) {
                try self.writeLeaf(String{ .str = obj }, id);
            } else if (comptime util.isUIntType(T)) |_| {
                try self.writeLeaf(UInt{ .u = obj }, id);
            } else {
                var counter = Counter{};
                try obj.writeLeaf(&counter.interface);
    
                if (!isLeaf(id))
                    std.debug.panic("Leaf '{s}' should have odd Id, not {},", .{ @typeName(T), id });
                try writeVLC(id, self.out);
                try writeVLC(counter.size, self.out);
                try obj.writeLeaf(self.out);
            }
        }
        pub fn writeComposite(self: Self, obj: anytype, id: Id) !void {
            if (!isComposite(id))
                std.debug.panic("Composite '{s}' should have even Id, not {},", .{ @typeName(@TypeOf(obj)), id });
            try writeVLC(id, self.out);
            try obj.writeComposite(self);
            try writeVLC(close, self.out);
    
            // &perf: maybe it is better to leave this to the caller for ultimate performance?
            try self.out.flush();
        }
    };
    
    pub const TreeReader = struct {
        const Self = @This();
        const Header = struct {
            id: Id,
            size: usize = 0,
        };
    
        in: *std.Io.Reader,
        header: ?Header = null,
    
        // Returns false if there is a Id mismatch
        pub fn readLeaf(self: *Self, obj: anytype, id: Id, ctx: anytype) !bool {
            const T = @TypeOf(obj.*);
            if (comptime util.isStringType(T)) {
                var string = String{};
                const ret = try self.readLeaf(&string, id, ctx);
                obj.* = string.str;
                return ret;
            } else if (comptime util.isUIntType(T)) |_| {
                var uint = UInt{};
                const ret = try self.readLeaf(&uint, id, ctx);
                obj.* = std.math.cast(T, uint.u) orelse return Error.TooLarge;
                return ret;
            } else {
                const header = try self.readHeader();
    
                if (!isLeaf(header.id))
                    return false;
                if (id != header.id)
                    return false;
    
                const size = header.size;
                self.header = null;
    
                try obj.readLeaf(size, self.in, ctx);
    
                return true;
            }
        }
    
        // Returns false if there is a Id mismatch
        pub fn readComposite(self: *Self, obj: anytype, id: Id) !bool {
            {
                const header = try self.readHeader();
    
                if (!isComposite(header.id)) {
                    std.debug.print("Expected composite, received {}\n", .{header.id});
                    return false;
                }
                if (id != header.id) {
                    std.debug.print("Expected {}, found {}\n", .{ id, header.id });
                    return false;
                }
                self.header = null;
            }
    
            try obj.readComposite(self);
    
            {
                const header = try self.readHeader();
                if (header.id != close) {
                    std.debug.print("Expected close ({}), found {}\n", .{ close, header.id });
                    return false;
                }
                self.header = null;
            }
    
            return true;
        }
    
        pub fn readHeader(self: *Self) !Header {
            if (self.header) |header|
                return header;
    
            const id = try readVLC(Id, self.in);
            const size = if (isLeaf(id)) try readVLC(usize, self.in) else 0;
            const header = Header{ .id = id, .size = size };
            self.header = header;
            return header;
        }
    
        pub fn isClose(self: *Self) !bool {
            const header = try self.readHeader();
            return header.id == close;
        }
    };
    
    // Util for working with a SimpleWriter
    pub fn writeUInt(u: anytype, io: *std.Io.Writer) !void {
        const T = @TypeOf(u);
        const len = (@bitSizeOf(T) - @clz(u) + 7) / 8;
        var buffer: [8]u8 = undefined;
        var uu: u128 = u;
        for (0..len) |ix| {
            buffer[len - ix - 1] = @truncate(uu);
            uu >>= 8;
        }
        try io.writeAll(buffer[0..len]);
    }
    pub fn readUInt(T: type, size: usize, io: *std.Io.Reader) !T {
        if (size > @sizeOf(T))
            return Error.TooLarge;
        var buffer: [@sizeOf(T)]u8 = undefined;
        const slice = buffer[0..size];
        try io.readSliceAll(slice);
        var u: T = 0;
        for (slice) |byte| {
            u <<= 8;
            u |= @as(T, byte);
        }
        return u;
    }
    
    pub fn writeVLC(u: anytype, io: *std.Io.Writer) !void {
        var uu: u128 = u;
        const max_byte_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;
    
        var buffer: [max_byte_count]u8 = undefined;
        const len = @max((@bitSizeOf(@TypeOf(uu)) - @clz(uu) + 6) / 7, 1);
        for (0..len) |ix| {
            const data: u7 = @truncate(uu);
            uu >>= 7;
    
            const msbit: u8 = if (ix == 0) 0x00 else 0x80;
    
            buffer[len - ix - 1] = msbit | @as(u8, data);
        }
    
        try io.writeAll(buffer[0..len]);
    }
    // Note: If reading a VLC of type T fails (eg., due to size constraint), there is no roll-back on 'sr'
    pub fn readVLC(T: type, io: *std.Io.Reader) !T {
        var uu: u128 = 0;
        const max_byte_count = (@bitSizeOf(@TypeOf(uu)) + 6) / 7;
        for (0..max_byte_count) |ix| {
            var ary: [1]u8 = undefined;
            try io.readSliceAll(&ary);
            const byte = ary[0];
            const data: u7 = @truncate(byte);
            uu <<= 7;
            uu |= @as(u128, data);
    
            // Check msbit to see if we need to continue
            const msbit = byte >> 7;
            if (msbit == 0)
                break;
    
            if (ix + 1 == max_byte_count)
                return Error.TooLarge;
        }
        return std.math.cast(T, uu) orelse return Error.TooLarge;
    }
    
    // SimpleWriter that counts the byte size of a leaf
    const Counter = struct {
        const Self = @This();
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    
        size: usize = 0,
        interface: std.Io.Writer = .{ .vtable = &vtable, .buffer = &.{} },
    
        pub fn writeAll(self: *Self, ary: []const u8) !void {
            self.size += ary.len;
        }
    
        fn drain(w: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            const self: *Counter = @fieldParentPtr("interface", w);
            self.size += data[0].len;
            return data[0].len;
        }
    };
    
    // Wrapper classes for primitives to support obj.writeLeaf()
    const String = struct {
        const Self = @This();
        str: []const u8 = &.{},
        fn writeLeaf(self: Self, io: *std.Io.Writer) !void {
            try io.writeAll(self.str);
        }
        fn readLeaf(self: *Self, size: usize, io: *std.Io.Reader, a: std.mem.Allocator) !void {
            const slice = try a.alloc(u8, size);
            try io.readSliceAll(slice);
            self.str = slice;
        }
    };
    const UInt = struct {
        const Self = @This();
        u: u128 = 0,
        fn writeLeaf(self: Self, io: *std.Io.Writer) !void {
            try writeUInt(self.u, io);
        }
        fn readLeaf(self: *Self, size: usize, io: *std.Io.Reader, _: void) !void {
            self.u = try readUInt(@TypeOf(self.u), size, io);
        }
    };
    
};

// Export from 'src/pipe.zig'
pub const pipe = struct {
    pub const Pipe = struct {
        const Self = @This();
        const reader_vtable: std.Io.Reader.VTable = .{
            .stream = stream,
        };
        const writer_vtable: std.Io.Writer.VTable = .{
            .drain = drain,
        };
        const Intern = struct {
            buffer: []u8,
            head: usize = 0,
            len: usize = 0,
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
                data: [2][]u8 = undefined,
    
            fn is_empty(i: @This()) bool {
                return i.len == 0;
            }
            fn is_full(i: @This()) bool {
                return i.len == i.buffer.len;
            }
    
            fn first(i: @This()) []const u8 {
                const len = @min(i.len, i.buffer.len - i.head);
                return i.buffer[i.head .. i.head + len];
            }
            fn second(i: @This()) []const u8 {
                const end = i.head + i.len;
                if (end <= i.buffer.len)
                    return &.{};
                const len = end - i.buffer.len;
                return i.buffer[0..len];
            }
            fn used(i: *Intern) []const []u8 {
                if (i.len == 0) {
                    // Buffer is empty
                    // Set head to 0 to optimize placement
                    i.head = 0;
                        return i.data[0..0];
                } else if (i.len == i.buffer.len) {
                    // Buffer is full
                        i.data[0] = i.buffer;
                        return i.data[0..1];
                } else if (i.head + i.len <= i.buffer.len) {
                    // Buffer is contiguous
                        i.data[0] = i.buffer[i.head .. i.head + i.len];
                        return i.data[0..1];
                } else {
                    // Buffer wraps over end
                        i.data[0] = i.buffer[i.head..];
                        i.data[1] = i.buffer[0 .. i.len - (i.buffer.len - i.head)];
                        return i.data[0..2];
                }
            }
            fn unused(i: *Intern) []const []u8 {
                if (i.len == 0) {
                    // Buffer is empty: unused is the full buffer
                    // Set head to 0 to optimize placement
                    i.head = 0;
                        i.data[0] = i.buffer;
                        return i.data[0..1];
                } else if (i.len == i.buffer.len) {
                    // Buffer is full: unused is empty
                        return i.data[0..0];
                } else if (i.head + i.len < i.buffer.len) {
                    // Buffer has unused space after
                    if (i.head == 0) {
                        // and no unused space in front
                            i.data[0] = i.buffer[i.head + i.len ..];
                            return i.data[0..1];
                    } else {
                        // and unused space in front
                            i.data[0] = i.buffer[i.head + i.len ..];
                            i.data[1] = i.buffer[0..i.head];
                            return i.data[0..2];
                    }
                } else {
                    // Unused buffer is contiguous and runs till i.head
                    const len = i.buffer.len - i.len;
                        i.data[0] = i.buffer[i.head - len .. i.head];
                        return i.data[0..1];
                }
            }
        };
    
        writer: std.Io.Writer,
        intern: Intern,
        reader: std.Io.Reader,
    
        pub fn init(wb: []u8, ib: []u8, rb: []u8) Self {
            return Self{
                .writer = .{
                    .vtable = &writer_vtable,
                    .buffer = wb,
                },
                .intern = Intern{
                    .buffer = ib,
                },
                .reader = .{
                    .vtable = &reader_vtable,
                    .buffer = rb,
                    .seek = 0,
                    .end = 0,
                },
            };
        }
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    
        pub fn format(self: Self, w: *std.Io.Writer) !void {
            try w.print(
                \\[Pipe]{{
                \\    [Writer](end:{}){{{s}}}
                \\    [Intern](head:{})(len:{}){{{s}{s}}}
                \\    [Reader](seek:{})(end:{}){{{s}}}
                \\}}
                \\
            ,
                .{
                    self.writer.end,
                    self.writer.buffer[0..self.writer.end],
    
                    self.intern.head,
                    self.intern.len,
                    self.intern.first(),
                    self.intern.second(),
    
                    self.reader.seek,
                    self.reader.end,
                    self.reader.buffer[self.reader.seek..self.reader.end],
                },
            );
        }
    
        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
            _ = splat;
    
            const p: *Pipe = @fieldParentPtr("writer", w);
            var intern = &p.intern;
    
            const copy_from_buffer = w.end > 0;
            var src = if (copy_from_buffer) w.buffer[0..w.end] else data[0];
            const orig_src_len = src.len;
    
            {
                intern.mutex.lock();
                defer intern.mutex.unlock();
    
                while (intern.is_full()) {
                    intern.cond.wait(&intern.mutex);
                }
    
                // Copy `src` into intern
                for (intern.unused()) |dst| {
                    const count = @min(dst.len, src.len);
                    @memcpy(dst[0..count], src[0..count]);
                    intern.len += count;
                    src = src[count..];
                }
    
                if (copy_from_buffer) {
                    // Move the remainder to the front, if any
                    if (src.len > 0) {
                        @memmove(w.buffer[0..src.len], src);
                    }
                    w.end = src.len;
                }
            }
    
            intern.cond.signal();
    
            return if (copy_from_buffer) 0 else orig_src_len - src.len;
        }
    
        fn stream(r: *std.Io.Reader, _: *std.Io.Writer, limit: std.Io.Limit) !usize {
            _ = limit;
    
            const p: *Pipe = @fieldParentPtr("reader", r);
            var intern = &p.intern;
    
            {
                intern.mutex.lock();
                defer intern.mutex.unlock();
    
                while (intern.is_empty()) {
                    intern.cond.wait(&intern.mutex);
                }
    
                if (r.seek == r.end) {
                    // All buffered data was read: reset the internal pointers to maximize read buffer size
                    r.seek = 0;
                    r.end = 0;
                }
    
                var dst = r.buffer[r.end..];
    
                // Copy internal data to r.buffer
                for (intern.used()) |src| {
                    const count = @min(dst.len, src.len);
                    @memcpy(dst[0..count], src[0..count]);
                    dst = dst[count..];
                    r.end += count;
                    intern.head += count;
                    intern.len -= count;
                }
                if (intern.head >= intern.buffer.len) {
                    intern.head -= intern.buffer.len;
                }
            }
    
            intern.cond.signal();
    
            return 0;
        }
    };
    
};

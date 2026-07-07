To compile `syrc` for Windows with Zig 0.16.0, you must correct `lib/std/Io/File.zig`.`Permissions` as follows:
```
    pub fn readOnly(self: @This()) bool {
        return toAttributes(self).READONLY;
    }
	
```

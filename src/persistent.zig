const std = @import("std");
const Allocator = std.mem.Allocator;
const db_mod = @import("db.zig");

pub const Command = struct {
    name: []const u8,
    script: []const u8,

    pub fn match(scratch: Allocator, name: []const u8, db: *db_mod.sqlite3) db_mod.Error!?Command {
        const script = try db_mod.scriptFromName(scratch, db, name) orelse return null;
        return Command{
            .name = name,
            .script = script,
        };
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("sqlite3.h");
});

const Config = @import("Config.zig");
const Minimum = Config.Minimum;
const Trust = Config.Trust;

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    InvalidTrust,
} || Allocator.Error;

pub const sqlite3 = c.sqlite3;

pub fn open(alloc: Allocator, path: []const u8) Error!*sqlite3 {
    var db: ?*sqlite3 = null;

    const path_z = try std.fmt.allocPrintSentinel(alloc, "{s}", .{path}, 0);
    defer alloc.free(path_z);

    const rc = c.sqlite3_open(path_z.ptr, &db);
    if (rc != c.SQLITE_OK or db == null) {
        if (db) |d| {
            std.log.err("sqlite open failed: {s}", .{std.mem.span(c.sqlite3_errmsg(d))});
            close(d);
        }
        return Error.OpenFailed;
    }
    return db.?;
}

pub fn close(db: *sqlite3) void {
    _ = c.sqlite3_close(db);
}

fn exec(db: *sqlite3, sql: [:0]const u8) Error!void {
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);
    if (rc != c.SQLITE_OK) {
        std.log.err("sqlite exec failed", .{});
        return Error.ExecFailed;
    }
}

pub fn schema(db: *sqlite3) !void {
    try exec(db,
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA synchronous=NORMAL;
        \\CREATE TABLE IF NOT EXISTS Commands (
        \\    name   TEXT PRIMARY KEY CHECK (length(name) <= 32),
        \\    script TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS Users (
        \\    uuid         TEXT PRIMARY KEY CHECK (length(uuid) == 36),
        \\    username     TEXT,
        \\    display_name TEXT,
        \\    phone_number TEXT,
        \\    trust        INT CHECK (trust <= 255)
        \\);
    );
}

fn dupeSqliteText(alloc: Allocator, stmt: *c.sqlite3_stmt, col: c_int) ![]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return "";

    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    const bytes = @as([*]const u8, @ptrCast(ptr))[0..n];

    return try alloc.dupe(u8, bytes);
}

pub fn setCommand(db: *sqlite3, name: []const u8, script: []const u8) Error!void {
    const sql: [:0]const u8 =
        \\INSERT INTO COMMANDS(name, script)
        \\VALUES(?1, ?2)
        \\ON CONFLICT(name) DO UPDATE SET script = excluded.script;
    ;

    var stmt: ?c.sqlite3_stmt = null;

    if (c.sqlite3_prepare(db, sql, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        std.log.err("prepare failed: {s}", .{std.mem.span(c.sqlite3_errmsg(db))});
        return Error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    if (c.sqlite3_bind_text(stmt.?, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return Error.BindFailed;
    }

    if (c.sqlite3_bind_text(stmt.?, 2, script.ptr, @intCast(script.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return Error.BindFailed;
    }

    const rc = c.sqlite3_step(stmt.?);
    if (rc != c.SQLITE_DONE) {
        std.log.err("step failed: {s}", .{std.mem.span(c.sqlite3_errmsg(db))});
        return Error.StepFailed;
    }
}

pub fn scriptFromName(alloc: Allocator, db: *sqlite3, name: []const u8) Error!?[]const u8 {
    const sql: [:0]const u8 =
        \\SELECT script FROM Commands WHERE name = ?1 LIMIT 1;
    ;

    var stmt_opt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt_opt, null) != c.SQLITE_OK or stmt_opt == null)
        return Error.PrepareFailed;

    const stmt = stmt_opt.?;
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return Error.BindFailed;
    }

    const step_rc = c.sqlite3_step(stmt);

    if (step_rc == c.SQLITE_DONE) {
        // None was found.
        return null;
    }

    if (step_rc != c.SQLITE_ROW) return Error.StepFailed;

    return try dupeSqliteText(alloc, stmt, 0);
}

pub const User = struct {
    uuid: []const u8,
    username: []const u8,
    display_name: []const u8,
    phone_number: []const u8,
    trust: Trust,

    pub fn canInteract(self: User, min: Minimum) bool {
        return self.trust >= min.to_interact;
    }

    pub fn canRawEval(self: User, min: Minimum) bool {
        return self.trust >= min.admin;
    }

    pub fn canProfile(self: User, min: Minimum) bool {
        return self.trust >= min.admin;
    }
};

fn getTrust(stmt: *c.sqlite3_stmt, col: c_int) !Trust {
    // sqlite3_column_int returns 0 if colums is NULL.
    const t_i32: i32 = c.sqlite3_column_int(stmt, col);
    if (t_i32 < 0 or t_i32 > 255) return Error.InvalidTrust;
    return @intCast(t_i32);
}

pub fn userFromUuid(scratch: Allocator, db: *sqlite3, uuid: []const u8) Error!?User {
    const sql: [:0]const u8 =
        \\SELECT uuid, username, display_name, phone_number, trust
        \\FROM Users
        \\WHERE uuid = ?1
        \\LIMIT 1;
    ;

    var stmt_opt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt_opt, null) != c.SQLITE_OK or stmt_opt == null)
        return Error.PrepareFailed;

    const stmt = stmt_opt.?;
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, uuid.ptr, @intCast(uuid.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return Error.BindFailed;
    }

    const step_rc = c.sqlite3_step(stmt);

    if (step_rc == c.SQLITE_DONE) {
        // None was found.
        return null;
    }

    if (step_rc != c.SQLITE_ROW) return Error.StepFailed;

    var ret = User{
        .uuid = "",
        .username = "",
        .display_name = "",
        .phone_number = "",
        .trust = 0,
    };

    // If anything fails mid dupe, then we have to free those already
    // initialized.
    errdefer {
        if (ret.uuid.len != 0) scratch.free(ret.uuid);
        if (ret.username.len != 0) scratch.free(ret.username);
        if (ret.display_name.len != 0) scratch.free(ret.display_name);
        if (ret.phone_number.len != 0) scratch.free(ret.phone_number);
    }

    ret.uuid = try dupeSqliteText(scratch, stmt, 0);
    ret.username = try dupeSqliteText(scratch, stmt, 1);
    ret.display_name = try dupeSqliteText(scratch, stmt, 2);
    ret.phone_number = try dupeSqliteText(scratch, stmt, 3);
    ret.trust = try getTrust(stmt, 4);

    return ret;
}

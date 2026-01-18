const std = @import("std");
const Allocator = std.mem.Allocator;
const signal = @import("signal.zig");
const script = @import("script.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var ctx = script.Context.init(arena, .{ .user = "nilsblix.67" });
    defer ctx.deinit();

    try ctx.fns.put("echo", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            var buf = std.ArrayList(u8).empty;
            for (args) |arg| {
                const val = try c.eval(arg);
                const slice = try val.asString();
                for (slice) |b| {
                    buf.append(c.arena, b) catch return error.Abort;
                }
            }
            std.debug.print("{s}\n", .{buf.items});
            return .void;
        }
    }.impl);

    try ctx.fns.put("let", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            const val = try args[0].asVar();
            const as = args[1];
            c.vars.put(val, as) catch return error.Abort;

            return .void;
        }
    }.impl);

    var args = std.process.args();
    _ = args.skip();
    const file_path = args.next() orelse return error.NoFilePath;

    var f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(&reader_buf);

    var cmd_buf = std.ArrayList(u8).empty;
    defer cmd_buf.deinit(alloc);
    try reader.interface.appendRemaining(alloc, &cmd_buf, .unlimited);
    const cmd = cmd_buf.items;

    var lexer = script.Lexer.init(file_path, cmd);

    var i: usize = 0;
    while (true) {
        const expr = lexer.nextExpression(arena) catch |e| switch (e) {
            error.ParseError => {
                const msg = try lexer.formatLastError(arena) orelse return error.Unexpected;
                std.debug.print("{s}\n", .{msg});
                return;
            },
            error.Unexpected, error.OutOfMemory, error.NoToken, error.InvalidToken => {
                std.log.err("Error while getting expresssion: {}\n", .{e});
                const loc = try lexer.loc.dump(arena);
                std.debug.print("Lexer.loc = `{s}`\n", .{loc});
                return;
            },
        } orelse break;

        i += 1;
        std.debug.print("========= Expression {d} ==========\n", .{i});
        _ = try ctx.eval(expr);
    }
}

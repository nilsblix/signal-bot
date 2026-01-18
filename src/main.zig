const std = @import("std");
const Allocator = std.mem.Allocator;
const signal = @import("signal.zig");
const script = @import("script.zig");
const builtin_fns = @import("builtin_fns.zig");
const Lexer = script.Lexer;
const Context = script.Context;
const Expression = script.Expression;

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

    var scratch_instance = std.heap.ArenaAllocator.init(alloc);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    var ctx = Context.init(arena, scratch, .{ .user = "some user" });
    defer ctx.deinit();

    for (builtin_fns.all) |b| {
        try ctx.fns.put(b.name, b.impl);
    }

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

    var lexer = Lexer.init(file_path, cmd);

    var i: usize = 0;
    while (true) {
        _ = scratch_instance.reset(.free_all);

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

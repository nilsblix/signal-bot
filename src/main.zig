const std = @import("std");
const Allocator = std.mem.Allocator;
const signal = @import("signal.zig");
const builtins = @import("builtins.zig");
const Parser = @import("Parser.zig");
const lang = @import("lang.zig");
const Context = lang.Context;
const Expression = lang.Expression;

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

    for (builtins.all) |b| {
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

    var parser = Parser.init(file_path, cmd);

    var i: usize = 0;
    while (true) {
        _ = scratch_instance.reset(.free_all);

        const res = try parser.nextExpression(arena);
        const expr = expr: switch (res) {
            .end => break,
            .err => |e| {
                const fmt = try e.format(scratch);
                defer scratch.free(fmt);
                std.debug.print("{s}\n", .{fmt});
                return;
            },
            .expr => |e| break :expr e,
        };

        i += 1;
        std.debug.print("========= Expression {d} ==========\n", .{i});
        _ = try ctx.eval(expr);
    }
}

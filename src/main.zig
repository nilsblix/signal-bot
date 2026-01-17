const std = @import("std");
const Allocator = std.mem.Allocator;
const signal = @import("signal.zig");
const script = @import("script.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    var ctx = script.Context.init(arena_alloc, .{ .user = "nilsblix.67" });
    defer ctx.deinit();

    try ctx.vars.put("my_name", .{ .string = "Nils Blix" });

    try ctx.fns.put("let", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            var val = try c.eval(args[0]);
            const name = try val.asString();

            const replacement = try c.eval(args[1]);
            c.vars.put(name, replacement) catch return error.Abort;

            return .void;
        }
    }.impl);

    try ctx.fns.put("echo", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            for (args) |arg| {
                const val = try c.eval(arg);
                const text = try val.asString();
                std.debug.print("{s}\n", .{text});
            }

            return .void;
        }
    }.impl);

    try ctx.fns.put("concat", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            if (args.len < 1) return error.InvalidArgumentsCount;

            var buffer = std.ArrayList(u8).empty;
            defer buffer.deinit(c.alloc);

            for (args) |arg| {
                const val = try c.eval(arg);
                const text = try val.asString();
                buffer.appendSlice(c.alloc, text) catch return error.Abort;
            }

            const concat = buffer.toOwnedSlice(c.alloc) catch return error.Abort;
            return .{ .string = concat };
        }
    }.impl);

    const unit_1 = script.Expression{
        .fn_call = .{
            .args = &.{ .{ .string = "my_runtime_name" }, .{ .string = "RuntimeNils" } },
            .name = "let",
        },
    };

    const unit_2 = script.Expression{
        .fn_call = .{
            .args = &.{ .{ .string = "other_runtime_name" }, .{ .string = "TheRuntimeBlix" } },
            .name = "let",
        },
    };

    const program = script.Expression{
        .fn_call = .{
            .args = &.{
                .{ .string = "Hello!" },
                .{ .fn_call = .{
                    .args = &.{
                        .{ .string = "These are my names: " },
                        .{ .@"var" = "my_runtime_name" },
                        .{ .string = " " },
                        .{ .@"var" = "other_runtime_name" }
                    },
                    .name = "concat",
                } },
            },
            .name = "echo",
        },
    };

    var res = ctx.eval(unit_1) catch |e| {
        std.log.err("Error was found while evaluating unit_1: {}\n", .{e});
        return;
    };
    std.debug.print("res = {any}\n", .{res});

    res = ctx.eval(unit_2) catch |e| {
        std.log.err("Error was found while evaluating unit_2: {}\n", .{e});
        return;
    };
    std.debug.print("res = {any}\n", .{res});

    res = ctx.eval(program) catch |e| {
        std.log.err("Error was found while evaluating program: {}\n", .{e});
        return;
    };

    std.debug.print("res = {any}\n", .{res});
}

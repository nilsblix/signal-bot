const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const signal = @import("signal.zig");
const script = @import("script.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer {
        const ok = arena.reset(.free_all);
        if (!ok) {
            std.log.err("Arena was not freed correctly.\n", .{});
        }
    }

    var ctx = script.Context.init(arena, .{ .user = "nilsblix.67" });
    defer ctx.deinit();

    try ctx.vars.put("my_name", .{ .string = "Nils Blix" });

    try ctx.fns.put("let", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            if (args.len != 2) return error.InvalidArgumentsCount;

            var val = try c.eval(args[0]);
            const name = try val.asString();

            const replacement = try c.eval(args[1]);
            c.vars.put(name, replacement) catch return error.Abort;

            return .@"void";
        }
    }.impl);

    try ctx.fns.put("echo", struct {
        pub fn impl(c: *script.Context, args: []const script.Expression) script.Error!script.Expression {
            for (args) |arg| {
                const val = try c.eval(arg);
                const text = try val.asString();
                std.debug.print("{s}\n", .{text});
            }

            return .@"void";
        }
    }.impl);

    const unit_1 = script.Expression{
        .fn_call = .{
            .args = &.{ .{ .string= "my_runtime_name" }, .{ .string = "Runtime name!!" } },
            .name = "let",
        },
    };

    const unit_2 = script.Expression{
        .fn_call = .{
            .args = &.{ .{ .string= "other_runtime_name" }, .{ .string = "Woah many names bro!" } },
            .name = "let",
        },
    };

    const program = script.Expression{
        .fn_call = .{
            .args = &.{ .{ .string = "Hello!" }, .{ .@"var" = "my_runtime_name" }, .{ .@"var" = "other_runtime_name" } },
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

    //
    // while (true) {
    //     const received = try signal.receive(alloc, &.{ .{ .prefixed_text_message = "!" }, .reaction });
    //     defer received.parsed.deinit();
    //
    //     const msg = received.parsed.value;
    //     const source = msg.envelope.source;
    //     const name = msg.sourceName() orelse continue;
    //
    //     switch (received.type) {
    //         .prefixed_text_message => |_| {
    //             const text = msg.textMessage() orelse continue;
    //
    //             const chat_msg = try std.fmt.allocPrint(alloc, "{s} [{s}]> {s}", .{name, source, text});
    //             defer alloc.free(chat_msg);
    //             std.debug.print("{s}\n", .{chat_msg});
    //         },
    //         .reaction => {
    //             const reaction = msg.reaction().?;
    //             if (reaction.isRemove) continue;
    //
    //             const target = reaction.targetAuthor;
    //             const chat_msg = try std.fmt.allocPrint(alloc, "{s} [{s}] reacted with {s} to {s}", .{name, source, reaction.emoji, target});
    //             defer alloc.free(chat_msg);
    //             std.debug.print("{s}\n", .{chat_msg});
    //         },
    //         else => {},
    //     }
    // }
}

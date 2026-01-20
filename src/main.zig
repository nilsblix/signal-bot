const std = @import("std");
const Signal = @import("Signal.zig");

const Parser = @import("Parser.zig");
const builtins = @import("builtins.zig");
const lang = @import("lang.zig");
const Context = lang.Context;
const Expression = lang.Expression;

pub fn main() !void {
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

    const chat = Signal.Chat{
        .user = "FIXME: NO LEAKS HERE!!!",
    };

    const event_text = "http://127.0.0.1:8080/api/v1/events";
    const rpc_text = "http://127.0.0.1:8080/api/v1/rpc";

    var signal = try Signal.init(alloc, chat, chat, event_text, rpc_text);
    defer signal.deinit();

    const echo = lang.FnCall.Impl{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) lang.Error!Expression {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(ctx.scratch);

                for (args) |arg| {
                    const val = try ctx.eval(arg);
                    switch (val) {
                        .int => |d| {
                            const s = try std.fmt.allocPrint(ctx.scratch, "{d}", .{d});
                            try buf.appendSlice(ctx.scratch, s);
                        },
                        .string => |s| {
                            try buf.appendSlice(ctx.scratch, s);
                        },
                        .void, .@"var", .fn_call => {
                            return error.InvalidCast;
                        },
                    }
                }

                ctx.signal.sendMessage(ctx.scratch, buf.items) catch return error.SignalError;
                return .void;
            }
        }.call,
    };

    const echo_builtin = builtins.Builtin{
        .name = "echo",
        .impl = echo,
    };

    const all = builtins.all ++ [_]builtins.Builtin{echo_builtin};

    while (true) {
        _ = scratch_instance.reset(.free_all);

        var context = Context.init(arena, scratch, &signal);
        for (all) |builtin| {
            try context.fns.put(builtin.name, builtin.impl);
        }

        var parsed = try signal.receive(alloc);
        defer parsed.deinit();

        const msg = parsed.value;

        if (msg.textMessage()) |text| {
            if (!std.mem.startsWith(u8, text, "!")) {
                continue;
            }

            if (text.len < 2) continue;

            const content = text[1..];
            var parser = Parser.init(null, content);
            const res = try parser.nextExpression(arena);
            switch (res) {
                .end => continue,
                .err => |err| {
                    const fmt = try err.format(scratch);
                    try signal.sendMessage(alloc, fmt);
                },
                .expr => |expr| {
                    _ = context.eval(expr) catch |e| switch (e) {
                        error.SignalError, error.OutOfMemory => continue,
                        error.InvalidCast => {
                            try signal.sendMessage(alloc, "error: Found invalid type-cast");
                        },
                        error.UnknownVariable => {
                            try signal.sendMessage(alloc, "error: Found unknown variable");
                        },
                        error.UnknownFn => {
                            try signal.sendMessage(alloc, "error: Found unknown function");
                        },
                        error.InvalidArgumentsCount => {
                            try signal.sendMessage(alloc, "error: Invalid argument count");
                        },
                        error.InvalidArgumentName => {
                            try signal.sendMessage(alloc, "error: Invalid argument name");
                        },
                        error.InvalidArgumentValue => {
                            try signal.sendMessage(alloc, "error: Invalid argument value");
                        },
                        error.Shadowing => {
                            try signal.sendMessage(alloc, "error: Variable shadows outside variable");
                        },
                    };
                },
            }
        }
    }
}

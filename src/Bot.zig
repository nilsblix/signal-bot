const std = @import("std");
const Allocator = std.mem.Allocator;

const Signal = @import("Signal.zig");
const Config = @import("Config.zig");

const lang = @import("lang.zig");
const Context = lang.Context;
const Expression = lang.Expression;
const Parser = @import("Parser.zig");

const builtins = @import("builtins.zig");

parsed: std.json.Parsed(Config),
signal: Signal,

const Bot = @This();

pub fn init(alloc: Allocator, config_path: []const u8) !Bot {
    var f = try std.fs.cwd().openFile(config_path, .{});
    defer f.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(&reader_buf);

    const n = try reader.getSize();
    const json = try reader.interface.readAlloc(alloc, n);
    defer alloc.free(json);

    const parsed = try Config.parse(alloc, json);

    const c = parsed.value;
    const signal = try Signal.init(alloc, c.target, c.source, c.event_uri, c.rpc_uri);

    return Bot{
        .parsed = parsed,
        .signal = signal,
    };
}

pub fn deinit(self: *Bot) void {
    self.parsed.deinit();
    self.signal.deinit();
}

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

fn config(self: *const Bot) Config {
    return self.parsed.value;
}

pub fn run(self: *Bot, alloc: Allocator) !void {
    const conf = self.config();

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var scratch_instance = std.heap.ArenaAllocator.init(alloc);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    while (true) {
        while (!arena_instance.reset(.free_all)) {
            std.log.warn("arena_instance did not reset correctly. trying again...\n", .{});
        }

        while (!scratch_instance.reset(.free_all)) {
            std.log.warn("arena_instance did not reset correctly. trying again...\n", .{});
        }

        var parsed = self.signal.receive(alloc) catch |e| {
            std.log.err("error while receiving message: {}\n", .{e});
            continue;
        };
        defer parsed.deinit();

        const message = parsed.value;
        const cmd = cmd: {
            const text = message.textMessage() orelse continue;
            if (!std.mem.startsWith(u8, text, conf.cmd_prefix)) continue;

            break :cmd text[conf.cmd_prefix.len..];
        };


        const message_source = message.envelope.source;

        if (conf.userFromNumber(message_source)) |author| {
            if (author.trust >= conf.minimum.to_eval_arbitrary) {
                self.evalArbitrary(arena, scratch, cmd, author) catch |e| {
                    const fmt = std.fmt.allocPrint(scratch, "error while evaluating arbitrary: {}", .{e}) catch
                        "error while evaluating arbitrary";

                    self.signal.sendMessage(scratch, fmt) catch {
                        std.log.err("{s}\n", .{fmt});
                    };
                };
            }
        }
    }
}

fn evalArbitrary(
    self: *Bot,
    arena: Allocator,
    scratch: Allocator,
    script: []const u8,
    author: Config.User,
) !void {
    var context = Context.init(arena, scratch, &self.signal);
    for (all) |builtin| {
        try context.fns.put(builtin.name, builtin.impl);
    }

    try context.vars.put("author", .{ .string = author.display_name });

    var parser = Parser.init(null, script);
    const res = try parser.nextExpression(arena);
    switch (res) {
        .end => return,
        .err => |err| {
            const fmt = try err.format(scratch);
            try self.signal.sendMessage(scratch, fmt);
        },
        .expr => |expr| {
            _ = context.eval(expr) catch |e| switch (e) {
                error.SignalError, error.OutOfMemory => return,
                error.InvalidCast => {
                    try self.signal.sendMessage(scratch, "error: Found invalid type-cast");
                },
                error.UnknownVariable => {
                    try self.signal.sendMessage(scratch, "error: Found unknown variable");
                },
                error.UnknownFn => {
                    try self.signal.sendMessage(scratch, "error: Found unknown function");
                },
                error.InvalidArgumentsCount => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument count");
                },
                error.InvalidArgumentName => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument name");
                },
                error.InvalidArgumentValue => {
                    try self.signal.sendMessage(scratch, "error: Invalid argument value");
                },
                error.Shadowing => {
                    try self.signal.sendMessage(scratch, "error: Variable shadows outside variable");
                },
            };
        },
    }
}

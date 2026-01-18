const std = @import("std");
const Allocator = std.mem.Allocator;
const signal = @import("signal.zig");
const script = @import("script.zig");
const Lexer = script.Lexer;
const Context = script.Context;
const Expression = script.Expression;

fn builtins(context: *Context) anyerror!void {
    try context.fns.put("echo", .{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) script.Error!Expression {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(ctx.scratch);

                for (args) |arg| {
                    const val = try ctx.eval(arg);
                    const slice = try val.asString();
                    try buf.appendSlice(ctx.scratch, slice);
                }
                std.debug.print("{s}\n", .{buf.items});
                return .void;
            }
        }.call,
    });

    try context.fns.put("if", .{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) script.Error!Expression {
                if (args.len != 3) return error.InvalidArgumentsCount;

                const val = try ctx.eval(args[0]);
                const cond = try val.asString();

                if (std.mem.eql(u8, cond, "true")) {
                    return try ctx.eval(args[1]);
                } else if (std.mem.eql(u8, cond, "false")) {
                    return try ctx.eval(args[2]);
                } else {
                    return error.InvalidArgumentValue;
                }
            }
        }.call,
    });

    try context.fns.put("eql", .{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) script.Error!Expression {
                if (args.len != 2) return error.InvalidArgumentsCount;

                const a = try ctx.eval(args[0]);
                const b = try ctx.eval(args[1]);

                return .{ .string = if (a.eql(b)) "true" else "false" };
            }
        }.call,
    });

    try context.fns.put("let", .{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) script.Error!Expression {
                if (args.len != 2) return error.InvalidArgumentsCount;

                const name = try args[0].asVar();
                const as = try ctx.eval(args[1]);
                try ctx.vars.put(name, as);
                return .void;
            }
        }.call,
    });

    try context.fns.put("define", .{
        .@"fn" = struct {
            pub fn call(_: ?*anyopaque, ctx: *Context, args: []const Expression) script.Error!Expression {
                if (args.len != 3) return error.InvalidArgumentsCount;

                const name = try args[0].asVar();

                const inner_args_fn_call = try args[1].asFnCall();

                if (!std.mem.eql(u8, inner_args_fn_call.name, "args")) {
                    return error.InvalidArgumentName;
                }

                const inner_args = inner_args_fn_call.args;
                const Payload = struct {
                    name: []const u8,
                    inner_args: []Expression,
                    to_eval: Expression,
                };


                const payload = try ctx.arena.create(Payload);
                payload.* = .{
                    .name = name,
                    .inner_args = @constCast(inner_args),
                    .to_eval = args[2],
                };

                const impl = script.FnCall.Impl{
                    .payload = payload,
                    .@"fn" = struct {
                        pub fn call(untyped_payload: ?*anyopaque, called_ctx: *Context, called_args: []const Expression) script.Error!Expression {
                            const p: *Payload = @ptrCast(@alignCast(untyped_payload.?));
                            if (p.inner_args.len != called_args.len) return error.InvalidArgumentsCount;

                            // We temporarily alias the argument vars as
                            // called_args, and then when we have called the
                            // function we remove them in order to prevent
                            // shadowing. Of course if the tried alias name
                            // already exists we report that as shadowing.
                            for (p.inner_args, 0..) |inner_arg, i| {
                                const @"var" = try inner_arg.asVar();
                                // Earlier I wanted to call this on the outer
                                // ctx as well, but I realized that since fns
                                // and vars are stored as maps, they wouldn't
                                // be copied deeply enough for the scope to
                                // stay the same as in the `define` statement.
                                const gop = try called_ctx.vars.getOrPut(@"var");
                                if (gop.found_existing) return error.VariableShadow;

                                gop.value_ptr.* = called_args[i];
                            }

                            const ret = try called_ctx.eval(p.to_eval);

                            for (p.inner_args) |inner_arg| {
                                const @"var" = try inner_arg.asVar();
                                if (!called_ctx.vars.remove(@"var")) {
                                    // This should never happen.
                                    unreachable;
                                }
                            }

                            return ret;
                        }
                    }.call
                };

                try ctx.fns.put(name, impl);

                return .void;
            }
        }.call,
    });
}

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

    var ctx = Context.init(arena, alloc, .{ .user = "nilsblix.67" });
    defer ctx.deinit();

    try builtins(&ctx);

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
        // FIXME: Check if we can create an arena for each expression, and then
        // dump after every expression. If we don't (which is what we currently
        // do) we leak until end of program, which is not good.
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

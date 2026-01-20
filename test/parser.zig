const std = @import("std");
const app = @import("app");
const lang = app.lang;
const Parser = app.Parser;
const Token = Parser.Token;
const Expression = lang.Expression;

const ExprCmp = struct {
    pub fn eq(a: Expression, b: Expression) bool {
        return switch (a) {
            .string => |as| switch (b) {
                .string => |bs| std.mem.eql(u8, as, bs),
                else => false,
            },
            .@"var" => |av| switch (b) {
                .@"var" => |bv| std.mem.eql(u8, av, bv),
                else => false,
            },
            .int => |an| switch (b) {
                .int => |bn| an == bn,
                else => false,
            },
            .fn_call => |af| switch (b) {
                .fn_call => |bf| blk: {
                    if (!std.mem.eql(u8, af.name, bf.name)) break :blk false;
                    if (af.args.len != bf.args.len) break :blk false;
                    for (af.args, bf.args) |a_arg, b_arg| {
                        if (!eq(a_arg, b_arg)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .void => b == .void,
        };
    }
};

test "advance" {
    const content = " \t\r\n  \n \t ";
    var parser = Parser.init(null, content);

    try std.testing.expectEqual(parser.cur, 0);
    try std.testing.expectEqual(parser.bol, 0);
    try std.testing.expectEqual(parser.row, 0);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 1);
    try std.testing.expectEqual(parser.bol, 0);
    try std.testing.expectEqual(parser.row, 0);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 2);
    try std.testing.expectEqual(parser.bol, 0);
    try std.testing.expectEqual(parser.row, 0);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 3);
    try std.testing.expectEqual(parser.bol, 0);
    try std.testing.expectEqual(parser.row, 0);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 4);
    try std.testing.expectEqual(parser.bol, 4);
    try std.testing.expectEqual(parser.row, 1);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 5);
    try std.testing.expectEqual(parser.bol, 4);
    try std.testing.expectEqual(parser.row, 1);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 6);
    try std.testing.expectEqual(parser.bol, 4);
    try std.testing.expectEqual(parser.row, 1);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 7);
    try std.testing.expectEqual(parser.bol, 7);
    try std.testing.expectEqual(parser.row, 2);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 8);
    try std.testing.expectEqual(parser.bol, 7);
    try std.testing.expectEqual(parser.row, 2);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 9);
    try std.testing.expectEqual(parser.bol, 7);
    try std.testing.expectEqual(parser.row, 2);

    parser.advance() catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(parser.cur, 10);
    try std.testing.expectEqual(parser.bol, 7);
    try std.testing.expectEqual(parser.row, 2);

    try std.testing.expectError(error.EndOfFile, parser.advance());
}

test "skip illegals" {
    const content = "  \r \t\n\n  token";
    var lexer = Parser.init(null, content);

    const kind = lexer.skipIllegals();
    try std.testing.expectEqual(kind, .symbol);

    const loc = lexer.loc();
    try std.testing.expectEqual(loc, Token.Location{ .filepath = null, .col = 2, .row = 2 });
}

fn expectNextToken(lexer: *Parser, tok: Token) anyerror!void {
    const res = lexer.nextToken();
    try std.testing.expectEqual(res.kind, tok.kind);
    try std.testing.expectEqual(res.loc, tok.loc);
    try std.testing.expectEqualStrings(res.text, tok.text);
}

test "get next token" {
    {
        const content = "\"Hello, world!\"";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .string,
            .text = "Hello, world!",
            .loc = .{
                .filepath = null,
                .col = 0,
                .row = 0,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "variable";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .symbol,
            .text = "variable",
            .loc = .{
                .filepath = null,
                .col = 0,
                .row = 0,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "longer_variable";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .symbol,
            .text = "longer_variable",
            .loc = .{
                .filepath = null,
                .col = 0,
                .row = 0,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "  (  ";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .oparen,
            .text = "(",
            .loc = .{
                .filepath = null,
                .col = 2,
                .row = 0,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "  \r\n\r\n )   ";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .cparen,
            .text = ")",
            .loc = .{
                .filepath = null,
                .col = 1,
                .row = 2,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "\t \t \n\n\n  ,  \n  ";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .comma,
            .text = ",",
            .loc = .{
                .filepath = null,
                .col = 2,
                .row = 3,
            },
        };
        try expectNextToken(&lexer, exp);
    }
    {
        const content = "   \t\t  \r\n \n \n ";
        var lexer = Parser.init(null, content);
        const exp = Token{
            .kind = .end,
            .text = "",
            .loc = .{
                .filepath = null,
                .col = 1,
                .row = 3,
            },
        };
        try expectNextToken(&lexer, exp);
    }
}

test "multiple next tokens" {
    const content =
        \\Hello world "This
        \\ is actually one string..." 34
        \\35     define(let, args(1, expr))
    ;

    var lexer = Parser.init(null, content);

    var tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "Hello");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "world");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "This\n is actually one string...");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "34");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "35");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "define");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "(");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "let");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, ",");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "args");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "(");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "1");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, ",");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, "expr");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, ")");

    tok = lexer.nextToken();
    try std.testing.expectEqualStrings(tok.text, ")");

    tok = lexer.nextToken();
    try std.testing.expectEqual(tok.kind, Token.Kind.end);
}

fn expectExpression(content: []const u8, exp: Parser.ExpressionResult) anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var scratch_instance = std.heap.ArenaAllocator.init(alloc);
    defer scratch_instance.deinit();

    const scratch = scratch_instance.allocator();

    var lexer = Parser.init(null, content);
    const res = try lexer.nextExpression(scratch);

    switch (res) {
        .end => {
            switch (exp) {
                .end => {},
                else => return error.TextUnexpectedResult,
            }
        },
        .err => |res_err| {
            switch (exp) {
                .err => |exp_err| {
                    try std.testing.expectEqual(res_err.loc, exp_err.loc);
                    try std.testing.expectEqualStrings(res_err.msg, exp_err.msg);
                },
                else => return error.TextUnexpectedResult,
            }
        },
        .expr => |res_expr| {
            switch (exp) {
                .expr => |exp_expr| {
                    if (!ExprCmp.eq(res_expr, exp_expr)) {
                        return error.TextUnexpectedResult;
                    }
                },
                else => return error.TextUnexpectedResult,
            }
        },
    }
}

test "get none expression" {
    const content =
        \\        
    ;

    try expectExpression(content, .end);
}

test "expression string" {
    const content =
        \\    "hello world!!"
        \\    
    ;

    try expectExpression(content, .{ .expr = .{ .string = "hello world!!" } });
}

test "expression int" {
    const content =
        \\    4647 
    ;

    try expectExpression(content, .{ .expr = .{ .int = 4647 } });
}

test "expression var" {
    const content =
        \\    some_var
    ;

    try expectExpression(content, .{ .expr = .{ .@"var" = "some_var" } });
}

test "expression function" {
    const content =
        \\echo("Hello, world!")
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "echo",
            .args = &.{.{ .string = "Hello, world!" }},
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

test "get larger next expression" {
    const content =
        \\echo(some_var, "Hello, world!", 3435)
    ;

    const expr = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{
            .{ .@"var" = "some_var" },
            .{ .string = "Hello, world!" },
            .{ .int = 3435 },
        },
    } };

    try expectExpression(content, .{ .expr = expr });
}

test "get empty args expression" {
    const content =
        \\noop()
    ;

    const expr = Expression{
        .fn_call = .{
            .args = &.{},
            .name = "noop",
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

test "get mixed args expression" {
    const content =
        \\mix(var_name, 42, "hi")
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "mix",
            .args = &.{
                .{ .@"var" = "var_name" },
                .{ .int = 42 },
                .{ .string = "hi" },
            },
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

test "get nested expression with whitespace" {
    const content =
        \\outer(
        \\    var_one,
        \\    1,
        \\    "a"
        \\)
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "outer",
            .args = &.{
                .{ .@"var" = "var_one" },
                .{ .int = 1 },
                .{ .string = "a" },
            },
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

test "get number expression" {
    const content = "12345";

    const expr = Expression{
        .int = 12345,
    };

    try expectExpression(content, .{ .expr = expr });
}

test "get string expression" {
    const content = "'hello'";

    const expr = Expression{
        .string = "hello",
    };

    try expectExpression(content, .{ .expr = expr });
}

test "complex expression" {
    const content =
        \\
        \\ repeat(echo('Hello, ', author, "!"), 20)
        \\
        \\
        \\ some_other_call(quote())
    ;

    const expr = Expression{ .fn_call = .{
        .name = "repeat",
        .args = &.{ .{ .fn_call = .{
            .name = "echo",
            .args = &.{
                .{ .string = "Hello, " },
                .{ .@"var" = "author" },
                .{ .string = "!" },
            },
        } }, .{ .int = 20 } },
    } };

    try expectExpression(content, .{ .expr = expr });
}

test "var at end of arguments" {
    const content =
        \\echo("Hello, ", name)
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "echo",
            .args = &.{ .{ .string = "Hello, " }, .{ .@"var" = "name" } },
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

test "number at end of arguments" {
    const content =
        \\echo("Hello, ", 6767)
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "echo",
            .args = &.{ .{ .string = "Hello, " }, .{ .int = 6767 } },
        },
    };

    try expectExpression(content, .{ .expr = expr });
}

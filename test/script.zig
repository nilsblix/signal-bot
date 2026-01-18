const std = @import("std");
const app = @import("app");
const script = app.script;
const Lexer = script.Lexer;
const Expression = script.Expression;

fn expectExpressionEqual(actual: Expression, expected: Expression) error{TextUnexpectedResult}!void {
    switch (expected) {
        .void => switch (actual) {
            .void => return,
            else => return error.TextUnexpectedResult,
        },
        .int => |expected_int| switch (actual) {
            .int => |actual_int| {
                if (actual_int != expected_int) return error.TextUnexpectedResult;
            },
            else => return error.TextUnexpectedResult,
        },
        .string => |expected_string| switch (actual) {
            .string => |actual_string| {
                if (!std.mem.eql(u8, actual_string, expected_string)) return error.TextUnexpectedResult;
            },
            else => return error.TextUnexpectedResult,
        },
        .@"var" => |expected_var| switch (actual) {
            .@"var" => |actual_var| {
                if (!std.mem.eql(u8, actual_var, expected_var)) return error.TextUnexpectedResult;
            },
            else => return error.TextUnexpectedResult,
        },
        .fn_call => |expected_fn| switch (actual) {
            .fn_call => |actual_fn| {
                if (!std.mem.eql(u8, actual_fn.name, expected_fn.name)) {
                    return error.TextUnexpectedResult;
                }
                if (actual_fn.args.len != expected_fn.args.len) {
                    return error.TextUnexpectedResult;
                }
                for (actual_fn.args, expected_fn.args) |actual_arg, expected_arg| {
                    try expectExpressionEqual(actual_arg, expected_arg);
                }
            },
            else => return error.TextUnexpectedResult,
        },
    }
}

fn expectExpression(content: []const u8, expr: Expression) error{ TextUnexpectedResult, OutOfMemory }!void {
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

    var lexer = Lexer.init(null, content);
    const res = lexer.nextExpression(arena) catch |e| {
        switch (e) {
            error.Unexpected => {
                const dumped = try lexer.loc.dump(alloc);
                std.log.err("Unexpected token at {s}\n", .{dumped});
            },
            error.NoToken, error.OutOfMemory, error.InvalidToken => {
                std.log.err("Error while getting next expression: {}\n", .{e});
            },
            error.ParseError => {
                if (lexer.formatLastError(alloc) catch null) |msg| {
                    defer alloc.free(msg);
                    std.log.err("{s}\n", .{msg});
                } else {
                    std.log.err("Parse error occurred\n", .{});
                }
            },
        }
        return error.TextUnexpectedResult;
    } orelse return error.TextUnexpectedResult;

    try expectExpressionEqual(res, expr);
}

test "get next expression" {
    const content =
        \\echo("Hello, world!")
    ;

    const expr = Expression{
        .fn_call = .{
            .name = "echo",
            .args = &.{.{ .string = "Hello, world!" }},
        },
    };

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
}

test "get number expression" {
    const content = "12345";

    const expr = Expression{
        .int = 12345,
    };

    try expectExpression(content, expr);
}

test "get string expression" {
    const content = "'hello'";

    const expr = Expression{
        .string = "hello",
    };

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
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

    try expectExpression(content, expr);
}

const ExpressionResult = union(enum) {
    parse_error: script.ParseError,
    expr: ?Expression,

    fn asParseError(self: ExpressionResult) error{InvalidCast}!script.ParseError {
        switch (self) {
            .parse_error => |e| return e,
            .expr => return error.InvalidCast,
        }
    }

    fn asExpression(self: ExpressionResult) error{InvalidCast}!?Expression {
        switch (self) {
            .parse_error => return error.InvalidCast,
            .expr => |e| return e,
        }
    }
};

fn expression(content: []const u8) (Lexer.NextExpressionError || error{TextUnexpectedResult})!ExpressionResult {
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

    var lexer = Lexer.init(null, content);
    const res = lexer.nextExpression(arena) catch |e| switch (e) {
        error.ParseError => {
            return .{
                .parse_error = lexer.last_error orelse return error.TextUnexpectedResult,
            };
        },
        else => return e,
    };

    return .{ .expr = res };
}

test "get next token" {
    const exp = std.testing.expect;

    {
        const content = "\"Hello, world!\"";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .string);
        try exp(std.mem.eql(u8, res.text, "Hello, world!"));
        try exp(res.loc.col == 0 and res.loc.row == 0);
    }
    {
        const content = "variable";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .symbol);
        try exp(std.mem.eql(u8, res.text, "variable"));
        try exp(res.loc.col == 0 and res.loc.row == 0);
    }
    {
        const content = "longer_variable";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .symbol);
        try exp(std.mem.eql(u8, res.text, "longer_variable"));
        try exp(res.loc.col == 0 and res.loc.row == 0);
    }
    {
        const content = "(  ";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .oparen);
        try exp(std.mem.eql(u8, res.text, "("));
        try exp(res.loc.col == 0 and res.loc.row == 0);
    }
    {
        const content = "  \r\n\r\n )   ";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .cparen);
        try exp(std.mem.eql(u8, res.text, ")"));
        try exp(res.loc.col == 1 and res.loc.row == 2);
    }
    {
        const content = "\t \t \n\n\n  ,  \n  ";
        var lexer = Lexer.init(null, content);
        const res = try lexer.nextToken() orelse {
            try exp(false);
            return;
        };
        try exp(res.kind == .comma);
        try exp(std.mem.eql(u8, res.text, ","));
        try exp(res.loc.col == 2 and res.loc.row == 3);
    }
}

test "parse string as sequence of tokens" {
    const content =
        \\Hello world "This
        \\ is actually one string..." 34
        \\35     define(let, args(1, expr))
    ;

    var lexer = Lexer.init(null, content);

    var tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "Hello"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "world"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "This\n is actually one string..."));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "34"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "35"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "define"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "("));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "let"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, ","));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "args"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "("));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "1"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, ","));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, "expr"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, ")"));

    tok = try lexer.nextToken() orelse return error.NoToken;
    try std.testing.expect(std.mem.eql(u8, tok.text, ")"));
}

test "expression eql" {
    var e1 = Expression{ .string = "hello world" };
    var e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(!e1.eql(e2));

    // NOTE: Wow pesky zig...
    // The string references static memory, which might not always be the case
    // in our strings. They might have the same value, but be allocated in
    // different places. I have manually checked this and it seems fine.
    e1 = Expression{ .string = "bonjour tout le monde" };
    e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(e1.eql(e2));

    e1 = .void;
    e2 = Expression{ .string = "bonjour tout le monde" };
    try std.testing.expect(!e1.eql(e2));

    e1 = .void;
    e2 = .void;
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .int = 45 };
    e2 = Expression{ .int = 45 };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .int = 35 };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .@"var" = "var" };
    e2 = Expression{ .@"var" = "variable" };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .@"var" = "var" };
    e2 = Expression{ .@"var" = "var" };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "echo",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .string = "name" }, .{ .int = 45 } },
    } };
    e2 = Expression{ .fn_call = .{
        .name = "world",
        .args = &.{ .{ .@"var" = "name" }, .{ .int = 45 } },
    } };
    try std.testing.expect(!e1.eql(e2));

    e1 = Expression{ .int = 1 };
    try std.testing.expect(!e1.eql(e2));
}

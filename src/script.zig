const std = @import("std");
const signal = @import("signal.zig");
const Allocator = std.mem.Allocator;

// This expression-based language is meant to fulfill a couple of things.
//
// I want to create a chatbot which interacts with a groupchat to perform
// certain commands, such as roll an n-sided dice, or select o group member to
// do something etc.
//
// To achieve this I want to have all of the bot's available commands stored in
// some database, and can therefore edit the available commands without having
// to recompile the program/even start and quit it.
//
// My thought is therefore to create a small expression-based language, with
// macro-like variable and function calling.
//
// ```script
// let(some_number, 6)
//
// define(ping, args(author), echo("@", author))
//
// repeat(ping("nilsblix"), some_number)
// ```
//
// The above script defines a sortof macro called `ping` which when called
// simply replaces ping(...) with its implementation. It then calls `ping` with
// the argument `"nilsblix"` 5 times.
//
// All the function builtins (let, define, repeat etc...) are defined outside of the script, as to make the
// language completely usage-agnostic.

const Token = struct {
    const Kind = enum {
        invalid,
        /// Starts with an alphabetic character, and may contain underscores.
        symbol,
        /// Starts with a number, and may only contain numbers.
        num,
        /// Is surrounded by either " or '.
        string,
        /// (
        oparen,
        /// )
        cparen,
        /// ,
        comma,

        fn get(b: u8) Kind {
            return switch (b) {
                'A'...'Z', 'a'...'z' => .symbol,
                '0'...'9' => .num,
                '"', '\'' => .string,
                '(' => .oparen,
                ')' => .cparen,
                ',' => .comma,
                else => .invalid,
            };
        }
    };

    const Loc = struct {
        filepath: ?[]const u8 = null,
        row: usize,
        col: usize,

        pub fn dump(self: Loc, alloc: Allocator) Allocator.Error![]u8 {
            if (self.filepath) |f| {
                return try std.fmt.allocPrint(alloc, "{s}:{d}:{d}", .{f, self.row, self.col});
            }

            return try std.fmt.allocPrint(alloc, "{d}:{d}", .{self.row, self.col});
        }
    };

    kind: Kind,
    text: []const u8,
    loc: Loc,

    pub fn dump(self: Token, alloc: Allocator) Allocator.Error![]u8 {
        const loc = try self.loc.dump(alloc);
        defer alloc.free(loc);
        return try std.fmt.allocPrint(alloc, "kind: {any}, text: `{s}`, loc: {s}", .{self.kind, self.text, loc});
    }
};

pub const Lexer = struct {
    filepath: ?[]const u8 = null,
    content: []const u8,
    cur: usize,
    col: usize,
    row: usize,

    pub fn init(filepath: ?[]const u8, content: []const u8) Lexer {
        return .{
            .filepath = filepath,
            .content = content,
            .cur = 0,
            .col = 0,
            .row = 0,
        };
    }

    pub fn loc(self: Lexer) Token.Loc {
        return .{
            .filepath = self.filepath,
            .row = self.row,
            .col = self.col,
        };
    }

    fn advance(self: *Lexer) error{EndOfFile}!void {
        const b = self.content[self.cur];
        if (b == '\n') {
            self.col = 0;
            self.row += 1;
        } else {
            self.col += 1;
        }

        self.cur += 1;
        if (self.cur == self.content.len) {
            return error.EndOfFile;
        }
    }

    fn chopLargerToken(self: Lexer, start: usize, kind: Token.Kind, l: Token.Loc) ?Token {
        switch (kind) {
            .symbol, .num => {
                return Token{
                    .kind = kind,
                    .text = self.content[start..],
                    .loc = l,
                };
            },
            .string => {
                return null;
            },
            .oparen, .cparen, .comma, .invalid => unreachable,
        }
    }

    pub fn nextToken(self: *Lexer) error{Unexpected}!?Token {
        var start = self.cur;
        var start_loc = self.loc();
        var token_kind = Token.Kind.invalid;

        while (true) {
            const b = self.content[self.cur];
            const byte_kind = Token.Kind.get(b);

            start_loc = self.loc();
            switch (byte_kind) {
                .symbol, .num, .string => {
                    start = self.cur;
                    token_kind = byte_kind;

                    self.advance() catch return self.chopLargerToken(start, token_kind, start_loc);
                    break;
                },
                // These are single-character tokens.
                .oparen, .cparen, .comma => {
                    defer { self.advance() catch {}; }
                    return Token{
                        .kind = byte_kind,
                        .text = self.content[self.cur..self.cur + 1],
                        .loc = start_loc,
                    };
                },
                .invalid => {
                    self.advance() catch return null;
                    continue;
                },
            }

            unreachable;
        }

        while (true) {
            const b = self.content[self.cur];
            const byte_kind = Token.Kind.get(b);

            switch (token_kind) {
                .invalid, .oparen, .cparen, .comma => unreachable,
                .symbol, .num => {
                    if (byte_kind != token_kind) {
                        // We have gone further than the current token. Time to
                        // return.
                        return Token{
                            .kind = token_kind,
                            .text = self.content[start..self.cur],
                            .loc = start_loc,
                        };
                    }
                },
                .string => {
                    if (byte_kind == .string) {
                        // We have arrived at the delimiter. We need to advance
                        // in order to get lexer's correct loc afterwards.
                        self.advance() catch {};
                        return Token{
                            .kind = token_kind,
                            .text = self.content[start + 1..self.cur - 1],
                            .loc = start_loc,
                        };
                    }
                },
            }

            self.advance() catch {
                // We can have situations such as contant = <variable> when the end
                // of the token is right before EOF.
                //
                // We know that `b` is not a delimiter to the current token, but if
                // we can just "chop" the current token depends on what kind.
                return self.chopLargerToken(start, token_kind, start_loc) orelse error.Unexpected;
            };
        }
    }
};

test "Lexer.nextToken single-token" {
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

test "Lexer.nextToken same content" {
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

pub const Error = error{
    /// An unknown error was encountered. Commonly `Allocator.Error.OutOfMemory`.
    Abort,
    /// Expression could not cast to the wanted type.
    InvalidCast,
    /// Tried to get an unknown variable from Context.vars.
    UnknownVariable,
    /// Tried to get an unknown function implementation from Context.fns.
    UnknownFn,
    /// An incorrect number of arguments were supplied to a function call.
    InvalidArgumentsCount,
};

pub const FnCall = struct {
    pub const Impl = *const fn (ctx: *Context, args: []const Expression) Error!Expression;

    args: []const Expression,
    /// Gets matched to an implementation (of type Impl) during
    /// runtime/evaluation. This makes it possible to define new functions
    /// during evaluation of the script.
    name: []const u8,
};

pub const Expression = union(enum) {
    @"void",
    int: u64,
    string: []const u8,
    @"var": []const u8,
    fn_call: FnCall,

    pub fn asInt(self: Expression) error{InvalidCast}!u64 {
        return switch (self) {
            .int => |d| d,
            .@"void", .string, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asString(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .@"void", .int, .@"var", .fn_call => error.InvalidCast,
        };
    }
};

pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    target: signal.Target,

    /// Macro-style replacement. When using a variable in a script, the program
    /// simply replaces that variable with the corresponding expression.
    vars: std.StringHashMap(Expression),
    /// Similar to `vars`, except that it replaces the function call with the
    /// expression result of the function.
    fns: std.StringHashMap(FnCall.Impl),

    pub fn init(arena: std.heap.ArenaAllocator, target: signal.Target) Context {
        const vars = std.StringHashMap(Expression).init(arena.child_allocator);
        const fns = std.StringHashMap(FnCall.Impl).init(arena.child_allocator);

        return .{
            .arena = arena,
            .target = target,
            .vars = vars,
            .fns = fns,
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
        self.fns.deinit();
    }

    pub fn eval(self: *Context, expr: Expression) Error!Expression {
        switch (expr) {
            .@"void", .int, .string => return expr,
            .@"var" => |v| {
                const replacement = self.vars.get(v) orelse return error.UnknownVariable;
                return try self.eval(replacement);
            },
            .fn_call => |f| {
                const impl = self.fns.get(f.name) orelse return error.UnknownFn;
                return try impl(self, f.args);
            },
        }
    }
};

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
                'A'...'Z', 'a'...'z', '_', '-' => .symbol,
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
                return try std.fmt.allocPrint(alloc, "{s}:{d}:{d}", .{ f, self.row, self.col });
            }

            return try std.fmt.allocPrint(alloc, "{d}:{d}", .{ self.row, self.col });
        }
    };

    kind: Kind,
    text: []const u8,
    loc: Loc,

    pub fn dump(self: Token, alloc: Allocator) Allocator.Error![]u8 {
        const loc = try self.loc.dump(alloc);
        defer alloc.free(loc);
        return try std.fmt.allocPrint(alloc, "kind: {any}, text: `{s}`, loc: {s}", .{ self.kind, self.text, loc });
    }
};

pub const ParseError = struct {
    loc: Token.Loc,
    msg: []const u8,
};

pub const Lexer = struct {
    content: []const u8,
    cur: usize,
    loc: Token.Loc,
    last_error: ?ParseError = null,

    pub fn init(filepath: ?[]const u8, content: []const u8) Lexer {
        return .{
            .content = content,
            .cur = 0,
            .loc = .{
                .filepath = filepath,
                .col = 0,
                .row = 0,
            },
        };
    }

    fn setError(self: *Lexer, loc: Token.Loc, msg: []const u8) void {
        self.last_error = .{ .loc = loc, .msg = msg };
    }

    pub fn clearLastError(self: *Lexer) void {
        self.last_error = null;
    }

    /// Format the last parse error in a compiler-friendly way.
    pub fn formatLastError(self: *Lexer, alloc: Allocator) Allocator.Error!?[]u8 {
        const err = self.last_error orelse return null;
        if (err.loc.filepath) |f| {
            return try std.fmt.allocPrint(alloc, "{s}:{d}:{d}: error: {s}", .{
                f,
                err.loc.row + 1,
                err.loc.col + 1,
                err.msg,
            });
        }
        return try std.fmt.allocPrint(alloc, "{d}:{d}: error: {s}", .{
            err.loc.row + 1,
            err.loc.col + 1,
            err.msg,
        });
    }

    fn advance(self: *Lexer) error{EndOfFile}!void {
        const b = self.content[self.cur];
        if (b == '\n') {
            self.loc.col = 0;
            self.loc.row += 1;
        } else {
            self.loc.col += 1;
        }

        self.cur += 1;
        if (self.cur == self.content.len) {
            return error.EndOfFile;
        }
    }

    fn chopLargerToken(self: Lexer, start: usize, kind: Token.Kind, loc: Token.Loc) ?Token {
        switch (kind) {
            .symbol, .num => {
                return Token{
                    .kind = kind,
                    .text = self.content[start..],
                    .loc = loc,
                };
            },
            .string => {
                return null;
            },
            .oparen, .cparen, .comma, .invalid => unreachable,
        }
    }

    pub fn nextToken(self: *Lexer) error{ Unexpected, ParseError }!?Token {
        var start = self.cur;
        var start_loc = self.loc;
        var token_kind = Token.Kind.invalid;

        while (true) {
            if (self.cur >= self.content.len) return null;
            const b = self.content[self.cur];
            const byte_kind = Token.Kind.get(b);

            start_loc = self.loc;
            switch (byte_kind) {
                .symbol, .num, .string => {
                    start = self.cur;
                    token_kind = byte_kind;

                    self.advance() catch return self.chopLargerToken(start, token_kind, start_loc);
                    break;
                },
                // These are single-character tokens.
                .oparen, .cparen, .comma => {
                    defer {
                        self.advance() catch {};
                    }
                    return Token{
                        .kind = byte_kind,
                        .text = self.content[self.cur .. self.cur + 1],
                        .loc = start_loc,
                    };
                },
                .invalid => {
                    self.advance() catch return null;
                },
            }
        }

        while (true) {
            if (self.cur >= self.content.len) {
                if (token_kind == .string) {
                    self.setError(start_loc, "unterminated string literal");
                    return error.ParseError;
                }
                return self.chopLargerToken(start, token_kind, start_loc) orelse error.Unexpected;
            }

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
                            .text = self.content[start + 1 .. self.cur - 1],
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

    fn peekNextToken(self: *Lexer) error{ Unexpected, ParseError }!?Token {
        const cur = self.cur;
        const loc = self.loc;
        defer {
            self.cur = cur;
            self.loc = loc;
        }
        return try self.nextToken();
    }

    const NextExpressionError = error{ Unexpected, OutOfMemory, NoToken, InvalidToken, ParseError };

    pub fn nextExpression(self: *Lexer, arena: Allocator) NextExpressionError!?Expression {
        self.clearLastError();
        const tok = try self.nextToken() orelse return null;
        switch (tok.kind) {
            .symbol => {
                const next = try self.peekNextToken() orelse {
                    self.setError(tok.loc, "unexpected end of input after identifier");
                    return error.ParseError;
                };
                switch (next.kind) {
                    .oparen => {
                        // consume peeked '('
                        _ = try self.nextToken();
                        // `lexer` currently sits at the first argument or
                        // cparen. We therefore find the next non-comma token
                        // until we encounter a cparen, which becomes the
                        // arguments. For each argument we create a lexer, and
                        // gets the argument expression.
                        var args = std.ArrayList(Expression).empty;
                        while (true) {
                            const prev = self.cur;
                            const prev_loc = self.loc;
                            // We return error.Unexpected as we have to have a
                            // cparen to call a function. null from nextToken
                            // means EOF, therefore no cparen, which is
                            // unexpected syntax.
                            const arg_tok = try self.nextToken() orelse {
                                self.setError(self.loc, "expected ')' after arguments");
                                return error.ParseError;
                            };
                            switch (arg_tok.kind) {
                                .comma => continue,
                                .cparen => break,
                                .invalid, .oparen => {
                                    self.setError(arg_tok.loc, "unexpected token in argument list");
                                    return error.ParseError;
                                },
                                .symbol, .num, .string => {
                                    var arg_lexer = Lexer.init(self.loc.filepath, self.content);
                                    arg_lexer.cur = prev;
                                    arg_lexer.loc = prev_loc;

                                    const arg = arg_lexer.nextExpression(arena) catch |e| {
                                        if (e == error.ParseError) self.last_error = arg_lexer.last_error;
                                        return e;
                                    } orelse {
                                        self.setError(arg_tok.loc, "found <EOF> instead of ')' after arguments");
                                        return error.ParseError;
                                    };
                                    try args.append(arena, arg);

                                    self.cur = arg_lexer.cur;
                                    self.loc = arg_lexer.loc;
                                },
                            }
                        }
                        return Expression{
                            .fn_call = .{
                                .args = args.toOwnedSlice(arena) catch return error.OutOfMemory,
                                .name = tok.text,
                            },
                        };
                    },
                    .cparen, .comma => {
                        return Expression{ .@"var" = tok.text };
                    },
                    .invalid, .symbol, .num, .string => {
                        self.setError(next.loc, "expected '(' to start argument list");
                        return error.ParseError;
                    },
                }
            },
            .num => {
                const int = std.fmt.parseInt(u64, tok.text, 10) catch |e| {
                    std.log.warn("Token of type num could not be parsed as u64: {}\n", .{e});
                    self.setError(tok.loc, "invalid integer literal");
                    return error.InvalidToken;
                };
                return Expression{ .int = int };
            },
            .string => {
                return Expression{ .string = tok.text };
            },
            .invalid, .oparen, .cparen, .comma => {
                self.setError(tok.loc, "unexpected token");
                return error.ParseError;
            },
        }
    }
};

pub const Error = error{
    OutOfMemory,
    /// Expression could not cast to the wanted type.
    InvalidCast,
    /// Tried to get an unknown variable from Context.vars.
    UnknownVariable,
    /// Tried to get an unknown function implementation from Context.fns.
    UnknownFn,
    /// An incorrect number of arguments were supplied to a function call.
    InvalidArgumentsCount,
    /// Some functions may require that certain arguments are named in a
    /// certain way. Ex: `define(fn, args(...), ...impl...)` might require
    /// that fn's' arguments are wrapped in a function call named `args`.
    InvalidArgumentName,
    /// Some functions require that certain arguments have certain values,
    /// such as `if(cond, then, else)` which require that `cond` evaluates to
    /// either "true" or "false".
    InvalidArgumentValue,
    Shadowing,
};

pub const FnCall = struct {
    pub const Impl = struct {
        /// Used to catch some data in a closure-like fashion. Sometimes, ex:
        /// define in builtin_fns.zig, it is necessary to wrap some data to get
        /// certain vars or fns.
        payload: ?*anyopaque = null,
        @"fn": *const fn (payload: ?*anyopaque, ctx: *Context, args: []const Expression) Error!Expression,
    };

    args: []const Expression,
    /// Gets matched to an implementation (of type Impl) during
    /// runtime/evaluation. This makes it possible to define new functions
    /// during evaluation of the script.
    name: []const u8,
};

pub const Expression = union(enum) {
    void,
    int: u64,
    string: []const u8,
    @"var": []const u8,
    fn_call: FnCall,

    pub fn asInt(self: Expression) error{InvalidCast}!u64 {
        return switch (self) {
            .int => |d| d,
            .void, .string, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asString(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .void, .int, .@"var", .fn_call => error.InvalidCast,
        };
    }

    pub fn asVar(self: Expression) error{InvalidCast}![]const u8 {
        return switch (self) {
            .@"var" => |v| v,
            .void, .int, .string, .fn_call => error.InvalidCast,
        };
    }

    pub fn asFnCall(self: Expression) error{InvalidCast}!FnCall {
        return switch (self) {
            .fn_call => |f| f,
            .void, .int, .string, .@"var" => error.InvalidCast,
        };
    }

    pub fn eql(a: Expression, b: Expression) bool {
        switch (a) {
            .string => |a_str| switch (b) {
                .string => |b_str| {
                    return std.mem.eql(u8, a_str, b_str);
                },
                else => return false,
            },
            .@"var" => |a_var| switch (b) {
                .@"var" => |b_var| {
                    return std.mem.eql(u8, a_var, b_var);
                },
                else => return false,
            },
            .void, .int, .fn_call => {
                return std.meta.eql(a, b);
            },
        }
    }
};

pub const Context = struct {
    /// Be careful with this arena. `Context` is a very long-living structure,
    /// so only allocate on the arena if absolutely necessary, ex permanent
    /// memory storage.
    arena: Allocator,
    /// Use this inside functions to not leak memory in the long run. Gets
    /// reset after evaluating every master expression (i.e expressions at the
    /// root level).
    scratch: Allocator,
    target: signal.Target,

    /// Macro-style replacement. When using a variable in a script, the program
    /// simply replaces that variable with the corresponding expression.
    vars: std.StringHashMap(Expression),
    /// Similar to `vars`, except that it replaces the function call with the
    /// expression result of the function.
    fns: std.StringHashMap(FnCall.Impl),

    pub fn init(arena: Allocator, scratch: Allocator, target: signal.Target) Context {
        const vars = std.StringHashMap(Expression).init(arena);
        const fns = std.StringHashMap(FnCall.Impl).init(arena);

        return .{
            .arena = arena,
            .scratch = scratch,
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
            .void, .int, .string => return expr,
            .@"var" => |v| {
                const replacement = self.vars.get(v) orelse return error.UnknownVariable;
                return try self.eval(replacement);
            },
            .fn_call => |f| {
                const impl = self.fns.get(f.name) orelse return error.UnknownFn;
                return try impl.@"fn"(impl.payload, self, f.args);
            },
        }
    }
};

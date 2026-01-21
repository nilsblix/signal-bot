const std = @import("std");
const Allocator = std.mem.Allocator;
const lang = @import("lang.zig");
const Expression = lang.Expression;

const Parser = @This();

filepath: ?[]const u8,
content: []const u8,
/// Logical position in `content`.
cur: usize,
/// Position in `content` of beginning of line.
bol: usize,
/// Current row.
row: usize,

pub const Token = struct {
    pub const Kind = enum {
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
        /// End of file.
        end,
        illegal,

        fn get(b: u8) Kind {
            return switch (b) {
                'A'...'Z', 'a'...'z', '_', '-' => .symbol,
                '0'...'9' => .num,
                '"', '\'' => .string,
                '(' => .oparen,
                ')' => .cparen,
                ',' => .comma,
                0 => .end,
                else => .illegal,
            };
        }
    };

    pub const Location = struct {
        filepath: ?[]const u8 = null,
        row: usize,
        col: usize,

        pub fn dump(self: Location, alloc: Allocator) Allocator.Error![]u8 {
            if (self.filepath) |f| {
                return try std.fmt.allocPrint(alloc, "{s}:{d}:{d}", .{ f, self.row, self.col });
            }

            return try std.fmt.allocPrint(alloc, "{d}:{d}", .{ self.row, self.col });
        }
    };

    kind: Kind,
    text: []const u8,
    loc: Location,

    pub fn dump(self: Token, alloc: Allocator) Allocator.Error![]u8 {
        const loc_slice = try self.loc.dump(alloc);
        defer alloc.free(loc_slice);
        return try std.fmt.allocPrint(alloc, "kind: {any}, text: `{s}`, loc: {s}", .{ self.kind, self.text, loc_slice });
    }
};

pub fn init(filepath: ?[]const u8, content: []const u8) Parser {
    return .{
        .filepath = filepath,
        .content = content,
        .cur = 0,
        .bol = 0,
        .row = 0,
    };
}

pub fn formatLastError(self: *Parser, alloc: Allocator) Allocator.Error!?[]u8 {
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

// Zero-indexed location.
pub fn loc(self: Parser) Token.Location {
    return .{
        .filepath = self.filepath,
        .col = self.cur - self.bol,
        .row = self.row,
    };
}

/// Checks before and after advancing one step for EOF.
pub fn advance(self: *Parser) error{EndOfFile}!void {
    if (self.cur >= self.content.len) {
        return error.EndOfFile;
    }

    const b = self.content[self.cur];
    if (b == '\n') {
        self.bol = self.cur + 1;
        self.row += 1;
    }

    self.cur += 1;
}

pub fn skipIllegals(self: *Parser) Token.Kind {
    while (true) {
        if (self.cur >= self.content.len) return .end;
        const b = self.content[self.cur];
        const kind = Token.Kind.get(b);

        if (kind != .illegal) {
            return kind;
        }

        self.advance() catch return .end;
    }
}

fn end(self: Parser) Token {
    return .{
        .kind = .end,
        .text = "",
        .loc = self.loc(),
    };
}

pub fn nextToken(self: *Parser) Token {
    const kind = self.skipIllegals();
    const start = self.cur;
    const start_loc = self.loc();

    switch (kind) {
        .symbol, .num => {
            while (true) {
                const byte_kind = byte_kind: {
                    self.advance() catch break :byte_kind .end;
                    if (self.cur >= self.content.len) break :byte_kind .end;
                    const b = self.content[self.cur];
                    break :byte_kind Token.Kind.get(b);
                };
                if (byte_kind != kind) {
                    return Token{
                        .kind = kind,
                        .text = self.content[start..self.cur],
                        .loc = start_loc,
                    };
                }
            }
        },
        .string => {
            while (true) {
                self.advance() catch return self.end();
                if (self.cur >= self.content.len) return self.end();
                const b = self.content[self.cur];
                if (Token.Kind.get(b) == .string) {
                    // We don't care about eof, as next time we might call
                    // self.advance it will be caught then.
                    defer {
                        self.advance() catch {};
                    }
                    return Token{
                        .kind = .string,
                        .text = self.content[start + 1 .. self.cur],
                        .loc = start_loc,
                    };
                }
            }
        },
        .oparen, .cparen, .comma, .illegal => {
            self.advance() catch return self.end();

            return Token{
                .kind = kind,
                .loc = start_loc,
                .text = self.content[self.cur - 1 .. self.cur],
            };
        },
        .end => return Token{
            .kind = .end,
            .text = "",
            .loc = start_loc,
        },
    }
}

pub const ParseError = struct {
    loc: Token.Location,
    msg: []const u8,

    pub fn format(err: ParseError, scratch: Allocator) Allocator.Error![]u8 {
        if (err.loc.filepath) |f| {
            return try std.fmt.allocPrint(scratch, "{s}:{d}:{d}: error: {s}", .{
                f,
                err.loc.row + 1,
                err.loc.col + 1,
                err.msg,
            });
        }

        return try std.fmt.allocPrint(scratch, "{d}:{d}: error: {s}", .{
            err.loc.row + 1,
            err.loc.col + 1,
            err.msg,
        });
    }

    fn illegal(scratch: Allocator, tok: Token) ParseError {
        return .{
            .loc = tok.loc,
            .msg = std.fmt.allocPrint(scratch, "found illegal token: {s}", .{tok.text}) catch "found illegal token",
        };
    }
};

fn peekNextToken(self: *Parser) Token {
    const cur = self.cur;
    const bol = self.bol;
    const row = self.row;
    defer {
        self.cur = cur;
        self.bol = bol;
        self.row = row;
    }
    return self.nextToken();
}

pub const ExpressionResult = union(enum) {
    end,
    expr: Expression,
    err: ParseError,
};

pub fn nextExpression(self: *Parser, arena: Allocator) Allocator.Error!ExpressionResult {
    _ = self.skipIllegals();
    const start_loc = self.loc();
    const tok = self.nextToken();

    switch (tok.kind) {
        .symbol => {
            const next_token = self.peekNextToken();

            switch (next_token.kind) {
                .oparen => {
                    // consume peeked '('
                    _ = self.nextToken();

                    var should_be_arg = true;
                    var args = std.ArrayList(Expression).empty;
                    while (true) {
                        const prev_cur = self.cur;
                        const prev_bol = self.bol;
                        const prev_row = self.row;

                        const arg_tok = self.nextToken();
                        switch (arg_tok.kind) {
                            .symbol, .num, .string => {
                                if (!should_be_arg) {
                                    return .{
                                        .err = .{
                                            .loc = arg_tok.loc,
                                            .msg = std.fmt.allocPrint(arena, "tried to parse argument `{s}` as function separator or delimiter", .{arg_tok.text}) catch "tried to parse argument as function separator or delimiter",
                                        },
                                    };
                                }

                                var arg_parser = Parser.init(self.filepath, self.content);
                                arg_parser.cur = prev_cur;
                                arg_parser.bol = prev_bol;
                                arg_parser.row = prev_row;

                                const res = try arg_parser.nextExpression(arena);
                                const arg = switch (res) {
                                    .end => return .{
                                        .err = .{
                                            .loc = arg_parser.loc(),
                                            .msg = "found unexpected end of file",
                                        },
                                    },
                                    .expr => |e| e,
                                    .err => |p| return .{ .err = p },
                                };

                                try args.append(arena, arg);

                                self.cur = arg_parser.cur;
                                self.bol = arg_parser.bol;
                                self.row = arg_parser.row;

                                should_be_arg = false;
                            },
                            .comma => {
                                if (should_be_arg) {
                                    return .{
                                        .err = .{
                                            .loc = arg_tok.loc,
                                            .msg = "tried to parse function argument as a ','",
                                        },
                                    };
                                }
                                should_be_arg = true;
                                continue;
                            },
                            .cparen => {
                                if (should_be_arg and args.items.len != 0) {
                                    return .{
                                        .err = .{
                                            .loc = arg_tok.loc,
                                            .msg = "tried to parse function argument as a ')'",
                                        },
                                    };
                                }
                                break;
                            },
                            .oparen => return .{
                                .err = .{
                                    .loc = arg_tok.loc,
                                    .msg = "found unexpected token in function call args: '('",
                                },
                            },
                            .end => return .{
                                .err = .{
                                    .loc = arg_tok.loc,
                                    .msg = "expected ')' to close function arguments",
                                },
                            },
                            .illegal => return .{ .err = ParseError.illegal(arena, arg_tok) },
                        }
                    }

                    return .{
                        .expr = .{
                            .fn_call = .{
                                .args = try args.toOwnedSlice(arena),
                                .name = tok.text,
                            },
                        },
                    };
                },
                .cparen, .comma, .end => return .{ .expr = .{ .variable = tok.text } },
                .symbol, .string, .num => return .{
                    .err = .{
                        .loc = next_token.loc,
                        .msg = "two non-function-calls cannot follow eachother",
                    },
                },
                .illegal => return .{ .err = ParseError.illegal(arena, next_token) },
            }
        },
        .num => {
            const n = std.fmt.parseInt(u64, tok.text, 10) catch |e| {
                const msg = std.fmt.allocPrint(arena, "could not parse int: {}", .{e}) catch "could not parse int";
                return .{
                    .err = .{
                        .loc = start_loc,
                        .msg = msg,
                    },
                };
            };
            return .{ .expr = Expression{ .int = n } };
        },
        .string => {
            return .{ .expr = Expression{ .string = tok.text } };
        },
        .oparen => return .{
            .err = .{
                .loc = start_loc,
                .msg = "expression cannot start with '('",
            },
        },
        .cparen => return .{
            .err = .{
                .loc = start_loc,
                .msg = "expression cannot start with ')'",
            },
        },
        .comma => return .{
            .err = .{
                .loc = start_loc,
                .msg = "expression cannot start with ','",
            },
        },
        .illegal => {
            return .{ .err = ParseError.illegal(arena, tok) };
        },
        .end => return .end,
    }
}

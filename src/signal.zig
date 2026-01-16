const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

pub const Filter = union(enum) {
    receipts,
    reaction,
    text_message,
    prefixed_text_message: []const u8,
    started_writing,
    stopped_writing,

    pub fn ok(self: Filter, msg: Message) bool {
        switch (self) {
            .receipts => unreachable,
            .reaction => {
                return msg.reaction() != null;
            },
            .text_message => {
                return msg.textMessage() != null;
            },
            .prefixed_text_message => |prefix| {
                const text = msg.textMessage() orelse return false;
                return std.mem.startsWith(u8, text, prefix);
            },
            .started_writing => {
                const typ = msg.typingMessage() orelse return false;
                return typ.action == .STARTED;
            },
            .stopped_writing => {
                const typ = msg.typingMessage() orelse return false;
                return typ.action == .STOPPED;
            },
        }
    }
};

/// Caller must call either `child.kill()` or `child.wait()`, as per Child
/// standards.
fn createChild(alloc: Allocator) Child {
    var c = Child.init(&.{}, alloc);
    c.stdin_behavior = .Ignore;
    c.stdout_behavior = .Pipe;
    c.stderr_behavior = .Ignore;
    return c;
}

fn deinitChild(c: *Child) void {
    _ = c.kill() catch |e| {
        std.log.err("Killing was unsuccessful: {}\n", .{e});
    };
    _ = c.wait() catch |e| {
        std.log.err("Waiting was unsuccessful: {}\n", .{e});
    };
}

const Received = struct {
    parsed: std.json.Parsed(Message),
    type: Filter,
};

/// Blocks until an okay message has been received. It then returns that okay
/// message, and kills the child process.
///
/// I am okay with killing the child process when having found an okay message,
/// as I would need to kill it either way when wanting to send a message, i.e
/// respond to that received message.
///
/// `deinit` needs to be called on the returned structure.
pub fn receive(alloc: Allocator, okay_filters: []const Filter) !Received {
    var c = createChild(alloc);
    defer deinitChild(&c);

    const argv = [_][]const u8{
        "signal-cli",
        "--output=json",
        "receive",
        "--timeout=-1",
        "--ignore-stories",
        "--ignore-attachments",
    };
    c.argv = @ptrCast(&argv);
    try c.spawn();

    var stdout = c.stdout orelse return error.ImpossibleSituation;

    var reader_buf: [4096]u8 = undefined;
    var reader = stdout.reader(&reader_buf);

    while (true) {
        const new = try reader.interface.takeDelimiter('\n') orelse return error.UnexpectedEof;

        std.debug.assert(new.len > 0);

        // Here we have updated the current message, and can safely parse it,
        // and then check it against the filters. If ok, then we can return the parsed
        // value.
        const line = try alloc.dupe(u8, new);
        errdefer alloc.free(line);
        const parsed = try Message.parse(alloc, line);

        const message = parsed.value;
        for (okay_filters) |filter| {
            if (filter.ok(message)) {
                return Received{
                    .parsed = parsed,
                    .type = filter,
                };
            }
        }

        // We do not defer this because if we return `parsed` we want the
        // caller to deinit that, not us.
        parsed.deinit();
        alloc.free(line);
    }
}

pub fn getStatus(c: *Child) ![]const u8 {
    var f = c.stdout orelse return error.InvalidState;
    var buf: [4096]u8 = undefined;
    const n = try f.readAll(&buf);
    return std.mem.trim(u8, buf[0..n], "\n");
}

pub const Target = union(enum) {
    group: []const u8,
    user: []const u8,
    phone: []const u8,

    pub const SendOptions = struct {
        items: [2][]const u8,
        len: usize,
    };

    pub fn sendOptions(self: Target) struct { [2][]const u8, usize } {
        return switch (self) {
            .group => |g| .{
                .{ "-g", g },
                2,
            },
            .user => |u| .{
                .{ "-u", u },
                2,
            },
            .phone => |p| .{
                .{ p, "" }, // The last `""` will be discarded when slicing.
                1,
            },
        };
    }
};

pub fn sendMessage(alloc: Allocator, message: []const u8, target: Target) !void {
    var c = createChild(alloc);
    defer deinitChild(&c);

    const options = target.sendOptions();
    const argv = [_][]const u8{ "signal-cli", "send", "-m", message } ++ options.@"0";
    c.argv = argv[0..4 + options.@"1"];

    try c.spawn();
    const out = try getStatus(&c);
    _ = std.fmt.parseInt(i64, out, 10) catch |e| switch (e) {
        error.Overflow => {},
        error.InvalidCharacter => {
            std.log.err("Invalid status-code after sending a message: `{s}`", .{out});
            return error.InvalidStatus;
        },
    };
}

pub const Message = struct {
    envelope: Envelope,
    account: []const u8,

    const Self = @This();

    const Timestamp = u64;

    const Envelope = struct {
        source: []const u8,
        sourceNumber: ?[]const u8 = null,
        sourceUuid: ?[]const u8 = null,
        sourceName: ?[]const u8 = null,
        sourceDevice: u16,
        timestamp: Timestamp,
        serverReceivedTimestamp: Timestamp,
        serverDeliveredTimestamp: Timestamp,
        dataMessage: ?DataMessage = null,
        typingMessage: ?TypingMessage = null,
    };

    const DataMessage = struct {
        const Reaction = struct {
            emoji: []const u8,
            targetAuthor: []const u8,
            targetAuthorNumber: []const u8,
            targetAuthorUuid: []const u8,
            targetSentTimestamp: Timestamp,
            isRemove: bool,
        };

        timestamp: Timestamp,
        message: ?[]const u8 = null,
        expiresInSeconds: u32,
        isExpirationUpdate: bool,
        viewOnce: bool,
        reaction: ?Reaction = null,
    };

    const TypingMessage = struct {
        const Action = enum {
            STARTED,
            STOPPED,
        };

        action: Action,
        timestamp: Timestamp,
    };

    /// Allocates all strings to not have any issues with passing around the
    /// `Parsed` structure after creation.
    pub fn parse(alloc: Allocator, json: []const u8) !std.json.Parsed(Self) {
        const opts = std.json.ParseOptions{
            .allocate = .alloc_always,
            .parse_numbers = true,
            .ignore_unknown_fields = true,
        };
        return std.json.parseFromSlice(Self, alloc, json, opts);
    }

    pub fn textMessage(self: *const Self) ?[]const u8 {
        const data = self.envelope.dataMessage orelse return null;
        return data.message;
    }

    pub fn reaction(self: *const Self) ?DataMessage.Reaction {
        const data = self.envelope.dataMessage orelse return null;
        return data.reaction;
    }

    pub fn typingMessage(self: *const Self) ?TypingMessage {
        return self.envelope.typingMessage;
    }

    pub fn sourceName(self: *const Self) ?[]const u8 {
        return self.envelope.sourceName;
    }

    pub fn sourceNumber(self: *const Self) ?[]const u8 {
        return self.envelope.sourceNumber;
    }
};

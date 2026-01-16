const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Caller must call either `child.kill()` or `child.wait()`, as per Child
/// standards.
fn createChild(alloc: Allocator) Child {
    var c = Child.init(&.{}, alloc);
    c.stdin_behavior = .Ignore;
    c.stdout_behavior = .Pipe;
    c.stderr_behavior = .Pipe;
    return c;
}

pub const Target = union(enum) {
    group: []const u8,
    user: []const u8,

    fn sendOptions(self: Target) [2][]const u8 {
        return switch (self) {
            .group => |g| .{ "-g", g },
            .user => |u| .{ "-u", u },
        };
    }
};

const StdoutError = error{InvalidState} || std.posix.ReadError;

pub fn stdout(c: *Child) StdoutError![]const u8 {
    var f = c.stdout orelse return error.InvalidState;
    var buf: [4096]u8 = undefined;
    const n = try f.readAll(&buf);
    return std.mem.trim(u8, buf[0..n], "\n");
}

const SendError = Child.SpawnError || StdoutError;

pub fn sendMessage(alloc: Allocator, message: []const u8, target: Target) SendError![]const u8 {
    var c = createChild(alloc);
    defer {
        _ = c.wait() catch |e| {
            std.log.err("Waiting was unsuccessful: {}\n", .{e});
        };
    }

    const t = target.sendOptions();
    const argv = [_][]const u8{ "signal-cli", "send", "-m", message } ++ t;
    c.argv = @ptrCast(&argv);

    try c.spawn();
    return stdout(&c);
}

/// Get the first new message.
///
/// `ping_ms` is the timeout between pings.
///
/// To iterate over all messages, then something like this would work:
///
/// ```zig
/// while(true) {
///     const msg = try receive(alloc);
/// }
/// ```
pub fn receive(alloc: Allocator) ![]const u8 {
    var c = createChild(alloc);
    defer {
        _ = c.wait() catch |e| {
            std.log.err("Waiting was unsuccessful: {}\n", .{e});
        };
    }

    const argv = [_][]const u8{
        "signal-cli",
        "--output=json",
        "receive",
        "--timeout=-1",
        "--max-messages=1",
        "--ignore-stories",
        "--ignore-attachments",
    };
    c.argv = @ptrCast(&argv);
    try c.spawn();

    var f = c.stdout orelse return error.ImpossibleState;
    var buf: [4096]u8 = undefined;
    var reader = f.reader(&buf);

    const msg = try reader.interface.takeDelimiter('\n') orelse return error.Unexpected;
    return try alloc.dupe(u8, msg);
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

    pub fn parse(alloc: Allocator, json: []const u8) !std.json.Parsed(Self) {
        return std.json.parseFromSlice(Self, alloc, json, .{ .parse_numbers = true, .ignore_unknown_fields = true });
    }

    pub fn textMessage(self: *const Self) ?[]const u8 {
        const data = self.envelope.dataMessage orelse return null;
        return data.message;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = std.http.Client;
const Signal = @This();

target: Chat,
listener: Listener,
rpc_uri: std.Uri,

pub fn init(
    alloc: Allocator,
    target: Chat,
    event_uri: []const u8,
    rpc_uri: []const u8,
) (Listener.InitError || std.Uri.ParseError)!Signal {
    return Signal{
        .target = target,
        .listener = try Listener.init(alloc, event_uri),
        .rpc_uri = try std.Uri.parse(rpc_uri),
    };
}

pub fn deinit(self: *Signal) void {
    self.listener.deinit();
}

pub const Chat = union(enum) {
    group: []const u8,
    user: []const u8,
    phone: []const u8,
};

const Listener = struct {
    client: Client,
    request: Client.Request,
    response: Client.Response,
    reader_buf: [4096]u8,
    reader: *std.Io.Reader,

    pub const InitError = error{InvalidHttpStatus} || std.Uri.ParseError || Client.RequestError || Client.Request.ReceiveHeadError;

    fn init(alloc: Allocator, uri_text: []const u8) InitError!Listener {
        var client = Client{ .allocator = alloc };
        const uri = try std.Uri.parse(uri_text);

        const extra_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
        };

        var req = try client.request(.GET, uri, .{
            .headers = .{ .user_agent = .{ .override = "signal-bot" } },
            .extra_headers = &extra_headers,
            .keep_alive = false,
        });

        try req.sendBodiless();
        var resp = try req.receiveHead(&.{});

        if (resp.head.status.class() != .success) {
            return error.InvalidHttpStatus;
        }

        var buf: [4096]u8 = undefined;
        const reader = resp.reader(&buf);

        return Listener{
            .client = client,
            .request = req,
            .response = resp,
            .reader_buf = buf,
            .reader = reader,
        };
    }

    fn deinit(self: *Listener) void {
        self.request.deinit();
        self.client.deinit();
    }

    /// Blocks until a message has been received.
    ///
    /// Will receive all messages coming to the current logged-in account. Only
    /// receives messages from the http-stream with the prefix `data:`.
    fn receiveJson(self: *Listener) error{ ReadFailed, StreamTooLong }![]u8 {
        while (true) {
            const incoming = try self.reader.takeDelimiter('\n') orelse continue;
            if (!std.mem.startsWith(u8, incoming, "data:")) {
                continue;
            }

            return incoming[5..];
        }
    }
};

pub fn receive(self: *Signal, alloc: Allocator) error{ OutOfMemory, ListenerError, MessageParseError }!std.json.Parsed(Message) {
    const json = self.listener.receiveJson() catch return error.ListenerError;
    const dupe = try alloc.dupe(u8, json);
    defer alloc.free(dupe);

    return Message.parse(alloc, dupe) catch return error.MessageParseError;
}

fn sendJsonRpc(self: *const Signal, alloc: Allocator, body: []const u8) !void {
    var client = Client{ .allocator = alloc };
    defer client.deinit();

    var req = try client.request(.POST, self.rpc_uri, .{
        .headers = .{
            .user_agent = .{ .override = "signal-bot" },
            .content_type = .{ .override = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.sendBodyComplete(@constCast(body));

    const resp = try req.receiveHead(&.{});
    const status = resp.head.status;
    if (status.class() != .success) {
        return error.InvalidHttpStatus;
    }
}

pub fn sendMessage(self: *const Signal, alloc: Allocator, msg: []const u8) !void {
    const Params = struct {
        message: []const u8,
        recipient: ?[]const []const u8 = null,
        username: ?[]const []const u8 = null,
        groupId: ?[]const u8 = null,
    };

    const Request = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: Params,
        id: usize,
    };

    var params = Params{
        .message = msg,
    };

    switch (self.target) {
        .group => |g| params.groupId = g,
        .user => |u| params.username = &.{u},
        .phone => |p| params.recipient = &.{p},
    }

    const req_body = Request{
        .method = "send",
        .params = params,
        .id = @intCast(std.time.microTimestamp()),
    };

    const json_body = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(req_body, .{})});
    defer alloc.free(json_body);

    try self.sendJsonRpc(alloc, json_body);
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

    pub const DataMessage = struct {
        const Reaction = struct {
            emoji: []const u8,
            targetAuthor: []const u8,
            targetAuthorNumber: []const u8,
            targetAuthorUuid: []const u8,
            targetSentTimestamp: Timestamp,
            isRemove: bool,
        };

        pub const GroupInfo = struct {
            groupId: []const u8,
            groupName: []const u8,
        };

        timestamp: Timestamp,
        message: ?[]const u8 = null,
        expiresInSeconds: u32,
        isExpirationUpdate: bool,
        viewOnce: bool,
        reaction: ?Reaction = null,
        groupInfo: GroupInfo,
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

    pub fn sourceSafeNumber(self: *const Self) []const u8 {
        return self.sourceNumber() orelse self.envelope.source;
    }

    pub fn groupInfo(self: *const Self) ?DataMessage.GroupInfo {
        const data = self.envelope.dataMessage orelse return null;
        return data.groupInfo;
    }
};

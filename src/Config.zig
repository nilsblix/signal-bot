const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Signal = @import("Signal.zig");

// We want the bot to be ran like this:
//
// ```console
// ./zig-out/bin/signal-bot --config path_to_config.json
// ````
//
// such that we can specify some advanced options.
//
// In the config we list all users with their name, username and phone-number
// to be able to map certain identity properties to each other. Here we could
// have a list of Users where each user has some data assigned to it such as
// phone_number, username, display_name, trust_level etc.
//
// The trust level property could be useful for enabling only certain users the
// ability to run potentially "dangerous" commands, such as evaluating raw
// nils-script expressions.

const Trust = u8;

pub const User = struct {
    username: []const u8,
    display_name: []const u8,
    phone_number: []const u8,
    trust: Trust,

    pub fn canInteract(self: User, min: Minimum) bool {
        return self.trust >= min.to_interact;
    }

    pub fn canRawEval(self: User, min: Minimum) bool {
        return self.trust >= min.to_eval_raw;
    }
};

const Minimum = struct {
    to_interact: Trust,
    to_write_cmd: Trust,
    to_eval_raw: Trust,
};

// The chat to send the results to.
target: Signal.Chat,
cmd_prefix: []const u8,

event_uri: []const u8,
rpc_uri: []const u8,

minimum: Minimum,
users: []const User,

const Config = @This();

pub fn parse(alloc: Allocator, body: []const u8) !json.Parsed(Config) {
    const opt = json.ParseOptions{
        .allocate = .alloc_always,
        .parse_numbers = true,
        .ignore_unknown_fields = true,
    };
    return try json.parseFromSlice(Config, alloc, body, opt);
}

pub fn userFromNumber(self: Config, account: []const u8) ?User {
    for (self.users) |user| {
        if (std.mem.eql(u8, account, user.phone_number)) {
            return user;
        }
    }

    return null;
}

pub fn userFromDisplayName(self: Config, dn: []const u8) ?User {
    for (self.users) |user| {
        if (std.mem.eql(u8, dn, user.display_name)) {
            return user;
        }
    }

    return null;
}

pub fn isTrustedMessage(self: Config, message: Signal.Message) bool {
    const number = message.sourceSafeNumber();
    const user = self.userFromNumber(number) orelse return false;
    // We do not allow the bot to accept/evaluate messages from users with
    // trust equal to zero.
    return user.trust >= self.minimum.to_interact;
}

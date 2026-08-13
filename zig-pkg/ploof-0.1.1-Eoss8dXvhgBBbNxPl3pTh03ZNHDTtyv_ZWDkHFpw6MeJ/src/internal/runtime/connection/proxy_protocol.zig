const std = @import("std");

const address = @import("../../../address.zig");
const forwarding = @import("../../../forwarding.zig");
const proxy_protocol_v2 = @import("../../proxy/protocol_v2.zig");

pub const ConfigureResult = enum(u2) {
    direct,
    pending,
    untrusted,
};

const Phase = enum(u2) {
    disabled,
    pending,
    finished,
};

pub const State = struct {
    decoder: proxy_protocol_v2.Decoder = proxy_protocol_v2.Decoder.init(),
    phase: Phase = .disabled,

    pub fn configure(
        self: *State,
        profile: anytype,
        transport_peer: address.Endpoint,
    ) ConfigureResult {
        self.* = .{};
        const trusted = profile.trustsEndpoint(transport_peer);
        if (profile.untrusted_peer == .reject and !trusted) {
            self.phase = .finished;
            return .untrusted;
        }
        return switch (profile.proxy_protocol) {
            .disabled => .direct,
            .v2_required => if (trusted) pending: {
                self.phase = .pending;
                break :pending .pending;
            } else untrusted: {
                self.phase = .finished;
                break :untrusted .untrusted;
            },
        };
    }

    pub fn feed(self: *State, bytes: []const u8) proxy_protocol_v2.FeedResult {
        std.debug.assert(self.phase == .pending);
        const result = self.decoder.feed(bytes);
        if (result.state != .need_more) self.phase = .finished;
        return result;
    }

    pub fn pending(self: *const State) bool {
        return self.phase == .pending;
    }

    pub fn abandon(self: *State) void {
        if (self.phase == .pending) self.phase = .finished;
    }
};

pub const Value = proxy_protocol_v2.Value;

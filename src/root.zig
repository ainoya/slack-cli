//! Slack CLI library root module
const std = @import("std");

pub const slack_client = @import("slack_client.zig");

test "basic test" {
    try std.testing.expect(true);
}

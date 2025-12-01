const std = @import("std");
const slack_client = @import("slack_client.zig");

const Command = enum {
    search,
    channel,
    user,
    help,
};

const SearchOptions = struct {
    query: []const u8,
    sort: []const u8 = "timestamp", // score or timestamp
    sort_dir: []const u8 = "desc", // asc or desc
    count: usize = 20,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const command_str = args[1];
    const command = std.meta.stringToEnum(Command, command_str) orelse {
        std.debug.print("Unknown command: {s}\n", .{command_str});
        try printHelp();
        return;
    };

    // help command doesn't require token
    if (command == .help) {
        try printHelp();
        return;
    }

    // Get Slack token from environment variable
    const token = std.process.getEnvVarOwned(allocator, "SLACK_TOKEN") catch |err| {
        std.debug.print("Error: SLACK_TOKEN environment variable is not set.\n", .{});
        std.debug.print("Please set it with: export SLACK_TOKEN=xoxb-your-token\n", .{});
        return err;
    };
    defer allocator.free(token);

    var client = slack_client.SlackClient.init(allocator, token);
    defer client.deinit();

    switch (command) {
        .search => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} search <query> [options]\n", .{args[0]});
                std.debug.print("Options:\n", .{});
                std.debug.print("  --sort=timestamp    Sort by timestamp (default) or score\n", .{});
                std.debug.print("  --sort-dir=desc     Sort direction: desc (default) or asc\n", .{});
                std.debug.print("  --count=20          Number of results (default: 20)\n", .{});
                std.debug.print("\nDate filters (add to query):\n", .{});
                std.debug.print("  after:YYYY-MM-DD    Messages after date\n", .{});
                std.debug.print("  before:YYYY-MM-DD   Messages before date\n", .{});
                std.debug.print("  on:YYYY-MM-DD       Messages on specific date\n", .{});
                std.debug.print("\nExamples:\n", .{});
                std.debug.print("  {s} search \"error\" --sort=timestamp --sort-dir=desc\n", .{args[0]});
                std.debug.print("  {s} search \"error after:2024-01-01\"\n", .{args[0]});
                std.debug.print("  {s} search \"bug before:2024-12-31\"\n", .{args[0]});
                return;
            }

            var options = SearchOptions{ .query = args[2] };

            // Parse options
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.startsWith(u8, arg, "--sort=")) {
                    options.sort = arg[7..];
                } else if (std.mem.startsWith(u8, arg, "--sort-dir=")) {
                    options.sort_dir = arg[11..];
                } else if (std.mem.startsWith(u8, arg, "--count=")) {
                    options.count = std.fmt.parseInt(usize, arg[8..], 10) catch 20;
                }
            }

            try client.searchMessagesWithOptions(options);
        },
        .channel => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} channel <channel-name>\n", .{args[0]});
                return;
            }
            try client.getChannelMessages(args[2]);
        },
        .user => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} user <username>\n", .{args[0]});
                return;
            }
            try client.getUserMessages(args[2]);
        },
        .help => {
            try printHelp();
        },
    }
}

fn printHelp() !void {
    std.debug.print(
        \\Slack CLI Tool
        \\
        \\Usage:
        \\  slack-cli <command> [options]
        \\
        \\Commands:
        \\  search <query>       Search messages across all channels
        \\  channel <name>       Get messages from a specific channel
        \\  user <username>      Get messages from a specific user
        \\  help                 Show this help message
        \\
        \\Environment Variables:
        \\  SLACK_TOKEN          Your Slack API token (required)
        \\
        \\Examples:
        \\  slack-cli search "error logs"
        \\  slack-cli channel general
        \\  slack-cli user john.doe
        \\
        \\
    , .{});
}

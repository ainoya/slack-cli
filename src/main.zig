const std = @import("std");
const slack_client = @import("slack_client.zig");
const config_module = @import("config.zig");

const Command = enum {
    search,
    channel,
    user,
    config,
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
    
    // config command doesn't require token
    if (command == .config) {
        if (args.len < 3) {
            std.debug.print("Usage: {s} config <set|get> [key] [value]\n", .{args[0]});
            return;
        }
        
        const subcmd = args[2];
        const config_manager = config_module.ConfigManager.init(allocator);

        if (std.mem.eql(u8, subcmd, "set")) {
            if (args.len < 5) {
                std.debug.print("Usage: {s} config set <key> <value>\n", .{args[0]});
                return;
            }
            try config_manager.set(args[3], args[4]);
            std.debug.print("✅ Updated {s}\n", .{args[3]});
        } else if (std.mem.eql(u8, subcmd, "get")) {
             if (args.len < 4) {
                std.debug.print("Usage: {s} config get <key>\n", .{args[0]});
                return;
            }
            const value = try config_manager.get(args[3]);
            if (value) |v| {
                defer allocator.free(v);
                std.debug.print("{s}\n", .{v});
            } else {
                std.debug.print("\n", .{});
            }
        } else {
             std.debug.print("Unknown config subcommand: {s}\n", .{subcmd});
        }
        return;
    }

    // Get Slack token from environment variable, fallback to config
    var token_owned: ?[]u8 = null;
    
    // 1. Try Environment Variable
    token_owned = std.process.getEnvVarOwned(allocator, "SLACK_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    
    // 2. Try Config File
    if (token_owned == null) {
        const config_manager = config_module.ConfigManager.init(allocator);
        // We need to manage the lifecycle of config data
        // For simplicity, let's load logic here or use a helper?
        // Let's use get for specific keys which returns allocated string
        token_owned = config_manager.get("slack_token") catch |err| blk: {
            // If error reading config (e.g. malformed), maybe warn? For now ignore.
             if (err != error.FileNotFound) {
                 std.debug.print("Warning: Failed to read config: {}\n", .{err});
             }
             break :blk null;
        } orelse null; 
        // Note: get returns ?[]const u8 allocated, which matches ?[]u8 (ignoring constness for free? No, dupe returns []u8 usually, wait)
        // allocator.dupe(u8, ...) returns []u8.
        // My config.zig get returns []const u8? Let's check.
        // It returns try allocator.dupe(u8, v). dupe returns []T. so []u8.
        // so it matches.
    }

    if (token_owned == null) {
        std.debug.print("Error: SLACK_TOKEN environment variable is not set and not found in config.\n", .{});
        std.debug.print("Please set it with: export SLACK_TOKEN=xoxb-your-token\n", .{});
        std.debug.print("Or use: {s} config set slack_token xoxb-your-token\n", .{args[0]});
        return error.TokenNotFound;
    }
    const token = token_owned.?;
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
        .config => {
           // handled above
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
        \\  config <subcmd>      Manage configuration (set/get)
        \\  help                 Show this help message
        \\
        \\Environment Variables:
        \\  SLACK_TOKEN          Your Slack API token (required if not set in config)
        \\
        \\Config:
        \\  Run 'slack-cli config set slack_token <token>' to save token permanently.
        \\
        \\Examples:
        \\  slack-cli search "error logs"
        \\  slack-cli channel general
        \\  slack-cli user john.doe
        \\  slack-cli config set slack_token xoxb-123...
        \\
        \\
    , .{});
}

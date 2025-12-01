const std = @import("std");

pub const SlackClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) SlackClient {
        return .{
            .allocator = allocator,
            .token = token,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *SlackClient) void {
        self.http_client.deinit();
    }

    /// Send GET request to Slack API (using Zig standard library HTTP client)
    fn makeGetRequest(self: *SlackClient, endpoint: []const u8, query_params: []const u8) ![]u8 {
        var url_buffer: [2048]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "https://slack.com/api/{s}?{s}", .{ endpoint, query_params });

        var auth_header_buffer: [512]u8 = undefined;
        const auth_header = try std.fmt.bufPrint(&auth_header_buffer, "Bearer {s}", .{self.token});

        // Create dynamic buffer for HTTP response
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer response_writer.deinit();

        // Execute HTTP request
        const response = try self.http_client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
        });

        // Check status code
        if (response.status != .ok) {
            std.debug.print("Slack API HTTP Error: {}\n", .{response.status});
            return error.SlackApiError;
        }

        // Get and return response body
        return try response_writer.toOwnedSlice();
    }

    /// Search messages with options
    pub fn searchMessagesWithOptions(self: *SlackClient, options: anytype) !void {
        const query = options.query;
        const sort = options.sort;
        const sort_dir = options.sort_dir;
        const count = options.count;

        // URL encode
        var encoded_query: std.ArrayList(u8) = .empty;
        defer encoded_query.deinit(self.allocator);

        for (query) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try encoded_query.append(self.allocator, c);
            } else if (c == ' ') {
                try encoded_query.append(self.allocator, '+');
            } else if (c == ':') {
                // Keep colon as-is (for date filters)
                try encoded_query.append(self.allocator, c);
            } else {
                try encoded_query.writer(self.allocator).print("%{X:0>2}", .{c});
            }
        }

        var query_params_buffer: [2048]u8 = undefined;
        const query_params = try std.fmt.bufPrint(
            &query_params_buffer,
            "query={s}&sort={s}&sort_dir={s}&count={d}",
            .{ encoded_query.items, sort, sort_dir, count },
        );

        const response = try self.makeGetRequest("search.messages", query_params);
        defer self.allocator.free(response);

        // Parse JSON and display results
        try self.printSearchResults(response);
    }

    /// Search messages (kept for backward compatibility)
    pub fn searchMessages(self: *SlackClient, query: []const u8) !void {
        const SearchOptions = struct {
            query: []const u8,
            sort: []const u8 = "timestamp",
            sort_dir: []const u8 = "desc",
            count: usize = 20,
        };
        try self.searchMessagesWithOptions(SearchOptions{ .query = query });
    }

    /// Get channel messages
    pub fn getChannelMessages(self: *SlackClient, channel_name: []const u8) !void {
        // First get channel ID
        const channel_id = try self.getChannelId(channel_name);
        defer self.allocator.free(channel_id);

        if (channel_id.len == 0) {
            std.debug.print("Channel '{s}' not found.\n", .{channel_name});
            return;
        }

        var query_params_buffer: [512]u8 = undefined;
        const query_params = try std.fmt.bufPrint(&query_params_buffer, "channel={s}&limit=20", .{channel_id});

        const response = try self.makeGetRequest("conversations.history", query_params);
        defer self.allocator.free(response);

        try self.printChannelMessages(response);
    }

    /// Get user messages
    pub fn getUserMessages(self: *SlackClient, username: []const u8) !void {
        // Get user ID
        const user_id = try self.getUserId(username);
        defer self.allocator.free(user_id);

        if (user_id.len == 0) {
            std.debug.print("User '{s}' not found.\n", .{username});
            return;
        }

        // URL encode
        var encoded_query: std.ArrayList(u8) = .empty;
        defer encoded_query.deinit(self.allocator);
        try encoded_query.writer(self.allocator).print("from:<@{s}>", .{user_id});

        var query_params_buffer: [1024]u8 = undefined;
        const query_params = try std.fmt.bufPrint(&query_params_buffer, "query={s}&count=20", .{encoded_query.items});

        const response = try self.makeGetRequest("search.messages", query_params);
        defer self.allocator.free(response);

        try self.printSearchResults(response);
    }

    /// Get channel ID from channel name
    fn getChannelId(self: *SlackClient, channel_name: []const u8) ![]u8 {
        const response = try self.makeGetRequest("conversations.list", "limit=1000");
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const channels = root.get("channels").?.array;

        for (channels.items) |channel| {
            const name = channel.object.get("name").?.string;
            if (std.mem.eql(u8, name, channel_name)) {
                const id = channel.object.get("id").?.string;
                return try self.allocator.dupe(u8, id);
            }
        }

        return try self.allocator.dupe(u8, "");
    }

    /// Get user ID from username
    fn getUserId(self: *SlackClient, username: []const u8) ![]u8 {
        const response = try self.makeGetRequest("users.list", "");
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const members = root.get("members").?.array;

        for (members.items) |member| {
            const name = member.object.get("name").?.string;
            if (std.mem.eql(u8, name, username)) {
                const id = member.object.get("id").?.string;
                return try self.allocator.dupe(u8, id);
            }
        }

        return try self.allocator.dupe(u8, "");
    }

    /// Convert timestamp to human-readable format
    fn formatTimestamp(ts_str: []const u8, buffer: []u8) ![]const u8 {
        const ts_float = try std.fmt.parseFloat(f64, ts_str);
        const ts_int: i64 = @intFromFloat(ts_float);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts_int) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    /// Print search results
    fn printSearchResults(self: *SlackClient, response: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Check for errors
        const ok = root.get("ok").?.bool;
        if (!ok) {
            const error_msg = root.get("error").?.string;
            std.debug.print("Slack API Error: {s}\n\n", .{error_msg});

            if (std.mem.eql(u8, error_msg, "not_allowed_token_type")) {
                std.debug.print("The search API requires a User Token, not a Bot Token.\n", .{});
                std.debug.print("Please create a User Token with the following scopes:\n", .{});
                std.debug.print("  - search:read\n", .{});
                std.debug.print("  - channels:history\n", .{});
                std.debug.print("  - channels:read\n", .{});
                std.debug.print("  - users:read\n", .{});
                std.debug.print("\nSee README.md for detailed instructions.\n", .{});
            }
            return;
        }

        const messages_obj = root.get("messages");
        if (messages_obj == null) {
            std.debug.print("No messages found.\n", .{});
            return;
        }

        const messages = messages_obj.?.object.get("matches").?.array;

        if (messages.items.len == 0) {
            std.debug.print("No messages found.\n", .{});
            return;
        }

        std.debug.print("\nFound {d} messages:\n", .{messages.items.len});
        std.debug.print("{s}\n", .{"=" ** 80});

        for (messages.items, 0..) |message, i| {
            const text = message.object.get("text").?.string;
            const username = message.object.get("username") orelse message.object.get("user") orelse {
                std.debug.print("\n[{d}] (unknown user)\n{s}\n", .{ i + 1, text });
                continue;
            };

            const user_str = if (username == .string) username.string else "unknown";
            std.debug.print("\n[{d}] {s}:\n{s}\n", .{ i + 1, user_str, text });

            // タイムスタンプを表示
            if (message.object.get("ts")) |ts| {
                var ts_buffer: [64]u8 = undefined;
                const timestamp = formatTimestamp(ts.string, &ts_buffer) catch "unknown time";
                std.debug.print("Posted: {s} UTC\n", .{timestamp});
            }

            if (message.object.get("channel")) |channel| {
                if (channel.object.get("name")) |channel_name| {
                    std.debug.print("Channel: #{s}\n", .{channel_name.string});
                }
            }
        }

        std.debug.print("\n{s}\n", .{"=" ** 80});
    }

    /// Print channel messages
    fn printChannelMessages(self: *SlackClient, response: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Check for errors
        const ok = root.get("ok").?.bool;
        if (!ok) {
            const error_msg = root.get("error").?.string;
            std.debug.print("Error: {s}\n", .{error_msg});
            return;
        }

        const messages = root.get("messages").?.array;

        if (messages.items.len == 0) {
            std.debug.print("No messages found.\n", .{});
            return;
        }

        std.debug.print("\nFound {d} messages:\n", .{messages.items.len});
        std.debug.print("{s}\n", .{"=" ** 80});

        for (messages.items, 0..) |message, i| {
            const text = message.object.get("text") orelse continue;
            const user = message.object.get("user") orelse {
                std.debug.print("\n[{d}] (system message)\n{s}\n", .{ i + 1, text.string });
                continue;
            };

            std.debug.print("\n[{d}] User {s}:\n{s}\n", .{ i + 1, user.string, text.string });

            if (message.object.get("ts")) |ts| {
                var ts_buffer: [64]u8 = undefined;
                const timestamp = formatTimestamp(ts.string, &ts_buffer) catch "unknown time";
                std.debug.print("Posted: {s} UTC\n", .{timestamp});
            }
        }

        std.debug.print("\n{s}\n", .{"=" ** 80});
    }
};

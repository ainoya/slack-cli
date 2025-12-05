const std = @import("std");

pub const SlackClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    http_client: std.http.Client,
    workspace_url: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) SlackClient {
        return .{
            .allocator = allocator,
            .token = token,
            .http_client = std.http.Client{ .allocator = allocator },
            .workspace_url = null,
        };
    }

    pub fn deinit(self: *SlackClient) void {
        if (self.workspace_url) |url| {
            self.allocator.free(url);
        }
        self.http_client.deinit();
    }

    /// Get workspace URL from auth.test API
    fn getWorkspaceUrl(self: *SlackClient) ![]const u8 {
        if (self.workspace_url) |url| {
            return url;
        }

        const response = try self.makeGetRequest("auth.test", "");
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("url")) |url_val| {
            // URL is like "https://workspace.slack.com/"
            const url_str = url_val.string;
            // Remove trailing slash if present
            const trimmed = if (url_str.len > 0 and url_str[url_str.len - 1] == '/')
                url_str[0 .. url_str.len - 1]
            else
                url_str;
            self.workspace_url = try self.allocator.dupe(u8, trimmed);
            return self.workspace_url.?;
        }

        return error.WorkspaceUrlNotFound;
    }

    /// Format message URL
    fn formatMessageUrl(workspace_url: []const u8, channel_id: []const u8, ts: []const u8, buffer: []u8) ![]const u8 {
        // Convert timestamp "1234567890.123456" to "p1234567890123456"
        var ts_buffer: [32]u8 = undefined;
        var ts_idx: usize = 0;
        for (ts) |c| {
            if (c != '.') {
                ts_buffer[ts_idx] = c;
                ts_idx += 1;
            }
        }
        return std.fmt.bufPrint(buffer, "{s}/archives/{s}/p{s}", .{ workspace_url, channel_id, ts_buffer[0..ts_idx] });
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

        const workspace_url = try self.getWorkspaceUrl();

        // Parse JSON and display results
        try printSearchResults(response, workspace_url);
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
        const workspace_url = try self.getWorkspaceUrl();

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

        try printChannelMessages(response, workspace_url, channel_id);
    }

    /// Get channel ID from channel name
    fn getChannelId(self: *SlackClient, channel_name: []const u8) ![]u8 {
        // Strip leading '#' if present
        const name_to_search = if (channel_name.len > 0 and channel_name[0] == '#')
            channel_name[1..]
        else
            channel_name;

        var cursor: ?[]const u8 = null;
        defer if (cursor) |c| self.allocator.free(c);

        while (true) {
            var query_params_buffer: [512]u8 = undefined;
            const query_params = if (cursor) |c|
                try std.fmt.bufPrint(&query_params_buffer, "limit=200&types=public_channel&cursor={s}", .{c})
            else
                try std.fmt.bufPrint(&query_params_buffer, "limit=200&types=public_channel", .{});

            const response = try self.makeGetRequest("conversations.list", query_params);
            defer self.allocator.free(response);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
            defer parsed.deinit();

            const root = parsed.value.object;

            const ok = root.get("ok").?.bool;
            if (!ok) {
                if (root.get("error")) |error_val| {
                    std.debug.print("Slack API Error: {s}\n", .{error_val.string});
                }
                return try self.allocator.dupe(u8, "");
            }

            const channels = root.get("channels").?.array;

            for (channels.items) |channel| {
                const name = channel.object.get("name").?.string;
                if (std.mem.eql(u8, name, name_to_search)) {
                    const id = channel.object.get("id").?.string;
                    return try self.allocator.dupe(u8, id);
                }
            }

            // Check for next page
            if (cursor) |c| self.allocator.free(c);
            cursor = null;

            if (root.get("response_metadata")) |metadata| {
                if (metadata.object.get("next_cursor")) |next| {
                    if (next.string.len > 0) {
                        cursor = try self.allocator.dupe(u8, next.string);
                        continue;
                    }
                }
            }

            break;
        }

        return try self.allocator.dupe(u8, "");
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

        const workspace_url = try self.getWorkspaceUrl();
        try printSearchResults(response, workspace_url);
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
    fn printSearchResults(response: []const u8, workspace_url: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{});
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

            // Display timestamp
            if (message.object.get("ts")) |ts| {
                var ts_buffer: [64]u8 = undefined;
                const timestamp = formatTimestamp(ts.string, &ts_buffer) catch "unknown time";
                std.debug.print("Posted: {s} UTC\n", .{timestamp});

                // Display URL
                if (message.object.get("channel")) |channel| {
                    if (channel.object.get("id")) |channel_id| {
                        var url_buffer: [256]u8 = undefined;
                        const msg_url = formatMessageUrl(workspace_url, channel_id.string, ts.string, &url_buffer) catch "unknown";
                        std.debug.print("URL: {s}\n", .{msg_url});
                    }
                }
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
    fn printChannelMessages(response: []const u8, workspace_url: []const u8, channel_id: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{});
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

                var url_buffer: [256]u8 = undefined;
                const msg_url = formatMessageUrl(workspace_url, channel_id, ts.string, &url_buffer) catch "unknown";
                std.debug.print("URL: {s}\n", .{msg_url});
            }
        }

        std.debug.print("\n{s}\n", .{"=" ** 80});
    }
};

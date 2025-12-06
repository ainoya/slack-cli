const std = @import("std");

pub const Config = struct {
    // Public configuration functionality (empty for now)

    pub fn deinit(self: *Config, _: std.mem.Allocator) void {
        _ = self;
    }
};

pub const SecretConfig = struct {
    slack_token: ?[]const u8 = null,

    pub fn deinit(self: *SecretConfig, allocator: std.mem.Allocator) void {
        if (self.slack_token) |t| allocator.free(t);
    }
};

pub const ConfigManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigManager {
        return ConfigManager{ .allocator = allocator };
    }

    fn getConfigPath(self: ConfigManager, filename: []const u8) ![]u8 {
        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();

        const home = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse return error.HomeNotFound;
        return std.fs.path.join(self.allocator, &[_][]const u8{ home, ".config", "slack-cli", filename });
    }

    pub fn loadSecret(self: ConfigManager) !SecretConfig {
        const path = try self.getConfigPath("secret.json");
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return SecretConfig{};
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB limit
        defer self.allocator.free(content);

        if (content.len == 0) return SecretConfig{};

        const parsed = try std.json.parseFromSlice(SecretConfig, self.allocator, content, .{ .ignore_unknown_fields = true });
        // We need to duplicate the strings because parsed.deinit() will free the source slice
        // but our Config struct is designed to own its memory if we want to modify it later.
        // Actually, std.json.parseFromSlice returns a Parsed(T) which owns the memory locally if allocated,
        // but here we are parsing from a slice. The strings in `parsed.value` point into `content`.
        // To make `Config` safe to return and use after `content` is freed, we must duplicate fields.

        var config = SecretConfig{};
        if (parsed.value.slack_token) |t| config.slack_token = try self.allocator.dupe(u8, t);

        parsed.deinit();
        return config;
    }

    fn jsonEscape(val: []const u8, writer: anytype) !void {
        for (val) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0C => try writer.writeAll("\\f"),
                else => try writer.writeByte(c),
            }
        }
    }

    pub fn saveSecret(self: ConfigManager, config: SecretConfig) !void {
        const path = try self.getConfigPath("secret.json");
        defer self.allocator.free(path);

        const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;

        try std.fs.cwd().makePath(dirname);

        const file = try std.fs.createFileAbsolute(path, .{ .mode = 0o600, .truncate = true });
        defer file.close();

        // Use strict ArrayList type to ensure methods exist
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        const writer = list.writer(self.allocator);
        try writer.writeAll("{\n");
        if (config.slack_token) |t| {
            try writer.writeAll("  \"slack_token\": \"");
            try jsonEscape(t, writer);
            try writer.writeAll("\"\n");
        }
        try writer.writeAll("}\n");

        try file.writeAll(list.items);
    }

    pub fn set(self: ConfigManager, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "slack_token")) {
            var secret = try self.loadSecret();
            defer secret.deinit(self.allocator);

            if (secret.slack_token) |old| self.allocator.free(old);
            secret.slack_token = try self.allocator.dupe(u8, value);

            try self.saveSecret(secret);
        } else {
            // For now we don't have other configs, so maybe just return error or handle dummy config.json
            return error.InvalidKey;
        }
    }

    pub fn get(self: ConfigManager, key: []const u8) !?[]u8 {
        // This is a bit tricky because we return a slice owned by current function scope's config?
        // No, we return a copy or we need to change how we return.
        // Or we return the config object and let caller read it?
        // Let's just return a duplicated string and let caller free it.

        if (std.mem.eql(u8, key, "slack_token")) {
            var secret = try self.loadSecret();
            defer secret.deinit(self.allocator);

            if (secret.slack_token) |v| return try self.allocator.dupe(u8, v);
        }
        return null;
    }
};

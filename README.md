# Slack CLI

Command-line tool for Slack built with Zig. Features include searching Slack messages, getting messages from specific channels, and searching for messages by specific users.

## Features

- **Message Search**: Search for messages across all Slack channels
- **Channel Message Retrieval**: Get latest messages from a specific channel
- **User Message Search**: Search for messages from a specific user

## Requirements

- Zig 0.15.2 or later
- Slack API token (User Token - token starting with `xoxp-`)

**Note**:
- **User Token** is required to use the search functionality. Bot Tokens (`xoxb-`) will not work.
- HTTP communication uses Zig standard library's `std.http.Client`.

## Installation

### Homebrew (macOS)

```bash
brew tap ainoya/tap
brew install ainoya/tap/slack-cli
```

### Install Zig

Using asdf:
```bash
asdf plugin add zig
asdf install zig latest
asdf global zig latest
```

Using Homebrew (macOS):
```bash
brew install zig
```

### Build the project

```bash
git clone <repository-url>
cd slack-cli
zig build
```

After a successful build, the executable will be generated at `zig-out/bin/slack-cli`.

## Setup

### Get Slack API Token

**Important**: **User Token** is required to use the search functionality. Bot Tokens cannot access the search API.

#### Creating a User Token

There are two ways to create a User Token: using an App Manifest (recommended) or configuring manually from scratch.

##### Option 1: Using App Manifest (Recommended)

1. Visit [Slack API](https://api.slack.com/apps)
2. Select "Create New App" → "From an app manifest"
3. Select the workspace and click "Next"
4. Copy and paste the following JSON into the text area (Select "JSON" tab if needed):

   ```json
   {
     "display_information": {
       "name": "Slack CLI"
     },
     "oauth_config": {
       "scopes": {
         "user": [
           "search:read",
           "channels:history",
           "channels:read",
           "users:read"
         ]
       }
     },
     "settings": {
       "org_deploy_enabled": false,
       "socket_mode_enabled": false,
       "token_rotation_enabled": false
     }
   }
   ```

5. Click "Next", then "Create"
6. Click "Install to Workspace" at the top of the page
7. Review permissions and click "Allow"
8. Copy the **"User OAuth Token"** (token starting with `xoxp-`)

##### Option 2: From scratch (Manual)

1. Visit [Slack API](https://api.slack.com/apps)
2. Select "Create New App" → "From scratch"
3. Choose app name and workspace, then create
4. Select "OAuth & Permissions" from the left menu
5. In the "User Token Scopes" section (**NOT Bot Token Scopes**), add the following scopes:
   - `search:read` - Message search (**required**)
   - `channels:history` - Get channel messages
   - `channels:read` - Read channel information
   - `users:read` - Read user information
6. Click "Install to Workspace" at the top of the page
7. Review permissions and click "Allow"
8. Copy the **"User OAuth Token"** (token starting with `xoxp-`)
   - ⚠️ NOT the "Bot User OAuth Token" (starting with `xoxb-`)

#### Verifying Token Type

- ✅ User Token: starts with `xoxp-` (required for search functionality)
- ❌ Bot Token: starts with `xoxb-` (cannot be used for search functionality)

### Configuration Command (Recommended)

You can save your token persistently using the config command:

```bash
slack-cli config set slack_token xoxp-your-token-here
```

To view your configured token:
```bash
slack-cli config get slack_token
```

### Set Environment Variable

Environment variables take precedence over the configuration file.

```bash
export SLACK_TOKEN=xoxp-your-token-here
```

Or add to `.bashrc` or `.zshrc` for persistence:
```bash
echo 'export SLACK_TOKEN=xoxb-your-token-here' >> ~/.zshrc
source ~/.zshrc
```

## Usage

### Display help

```bash
./zig-out/bin/slack-cli help
```

### Message search

Search for keywords across all channels:

```bash
# Basic search
./zig-out/bin/slack-cli search "error logs"

# Sort by timestamp (newest first) - default
./zig-out/bin/slack-cli search "error" --sort=timestamp --sort-dir=desc

# Sort by timestamp (oldest first)
./zig-out/bin/slack-cli search "error" --sort=timestamp --sort-dir=asc

# Sort by relevance
./zig-out/bin/slack-cli search "error" --sort=score

# Specify number of results
./zig-out/bin/slack-cli search "error" --count=50

# Date filters (include in query)
./zig-out/bin/slack-cli search "error after:2024-01-01"
./zig-out/bin/slack-cli search "bug before:2024-12-31"
./zig-out/bin/slack-cli search "deploy on:2024-11-19"

# Combined conditions
./zig-out/bin/slack-cli search "error after:2024-11-01 before:2024-11-30" --sort=timestamp --count=100
```

#### Search options

- `--sort=timestamp` or `--sort=score`: Sort method (default: timestamp)
- `--sort-dir=desc` or `--sort-dir=asc`: Sort direction (default: desc = newest first)
- `--count=N`: Number of results to retrieve (default: 20)

#### Date filters

You can specify date ranges by including the following in the query string:

- `after:YYYY-MM-DD`: Messages after specified date
- `before:YYYY-MM-DD`: Messages before specified date
- `on:YYYY-MM-DD`: Messages on specified date

### Get channel messages

Get latest messages from a specific channel:

```bash
./zig-out/bin/slack-cli channel general
```

### Search user messages

Search for messages from a specific user:

```bash
./zig-out/bin/slack-cli user john.doe
```

## Using with Cursor

You can use `slack-cli` with [Cursor](https://cursor.sh/)'s AI features to search Slack logs using natural language.

### Setup

1. Copy the [.cursor/rules/slack.mdc](.cursor/rules/slack.mdc) file to your local project's `.cursor/rules/` directory.
2. Ensure `slack-cli` is installed and the `SLACK_TOKEN` is set in your environment (or via config).

### Usage Example

In Cursor's chat or command bar, you can ask:

- "Check for deployment errors from last week"
- "Summarize the latest messages in #general"
- "What did @john.doe say about the database?"

Cursor will follow the rules in `slack.mdc` to execute `slack-cli` commands and summarize the output for you.

## Project structure

```
slack-cli/
├── build.zig           # Zig build configuration
├── build.zig.zon       # Package configuration
├── src/
│   ├── main.zig        # Entry point
│   ├── slack_client.zig # Slack API client
│   └── root.zig        # Library root module
└── README.md
```

## Development

### Run tests

```bash
zig build test
```

### Debug build

```bash
zig build
```

### Release build

```bash
zig build -Doptimize=ReleaseFast
```

## Troubleshooting

### "SLACK_TOKEN environment variable is not set" error

The `SLACK_TOKEN` environment variable is not set. Please refer to the Setup section above to set the token.

### "Channel not found" error

- Verify the channel name is correct
- For private channels, verify the Bot is invited to the channel

### "User not found" error

- Verify the username is correct (use user ID or username, not display name)

## License

MIT License

## Contributing

Issue reports and Pull Requests are welcome.

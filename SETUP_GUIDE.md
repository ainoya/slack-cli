# Slack User OAuth Token Setup Guide

This guide explains in detail how to obtain a User OAuth Token required to use the search functionality in Slack CLI.

## Steps

### 1. Access Slack API page

Visit [https://api.slack.com/apps](https://api.slack.com/apps).

### 2. Create or select an app

#### To create a new app:
1. Click the **"Create New App"** button in the top right
2. Select **"From scratch"**
3. Enter an app name (e.g., "Slack CLI Tool")
4. Select a workspace
5. Click **"Create App"**

#### To use an existing app:
1. Select an existing app from the list

### 3. Navigate to OAuth & Permissions page

1. Click **"OAuth & Permissions"** from the left menu

### 4. Add User Token Scopes

Scroll down the page to find the **"Scopes"** section.

**Important**: There are two sections:
- ❌ **Bot Token Scopes** - Not here
- ✅ **User Token Scopes** - Add here

In the **"User Token Scopes"** section:

1. Click the **"Add an OAuth Scope"** button
2. Add the following scopes one by one:
   - `search:read` ← **Most important**
   - `channels:history`
   - `channels:read`
   - `users:read`

### 5. Install to workspace

1. Scroll back to the top of the page
2. Find the **"OAuth Tokens for Your Workspace"** section
3. Click the **"Install to Workspace"** button (if not installed yet)
   - Or the **"Reinstall to Workspace"** button (if already installed)
4. Review the permissions screen
5. Click **"Allow"** or **"Authorize"** button

### 6. Copy the User OAuth Token

After installation completes, you'll return to the **"OAuth Tokens for Your Workspace"** section on the same page.

Two tokens will be displayed here:

```
OAuth Tokens for Your Workspace

User OAuth Token
xoxp-1234567890-xxxx
[Copy] ← Click this

Bot User OAuth Token
xoxb-xxxxxx
```

Copy the **"User OAuth Token"** (starting with `xoxp-`).

### 7. Set as environment variable

Run the following in your terminal:

```bash
export SLACK_TOKEN=xoxp-paste-your-token-here
```

To persist (recommended):

```bash
# For Zsh
echo 'export SLACK_TOKEN=xoxp-your-token' >> ~/.zshrc
source ~/.zshrc

# For Bash
echo 'export SLACK_TOKEN=xoxp-your-token' >> ~/.bashrc
source ~/.bashrc
```

### 8. Verify functionality

```bash
./zig-out/bin/slack-cli search "test"
```

## Troubleshooting

### "User OAuth Token" not displayed

**Cause**: User Token Scopes not added

**Solution**:
1. Return to "OAuth & Permissions" page
2. Check the "User Token Scopes" section at the bottom of the page
3. Verify scopes are added
4. After adding scopes, click "Reinstall to Workspace" again

### "not_allowed_token_type" error

**Cause**: Using Bot Token (`xoxb-`)

**Solution**:
1. Check environment variable: `echo $SLACK_TOKEN`
2. Verify token starts with `xoxp-`
3. If it starts with `xoxb-`, change to User OAuth Token

### "invalid_auth" error

**Cause**: Token is invalid or expired

**Solution**:
1. Generate a new token on Slack API page
2. Click "Reinstall to Workspace"
3. Set the new User OAuth Token as environment variable

## Security Notes

⚠️ **Important**: User OAuth Tokens have powerful permissions. Please note the following:

- Do not commit tokens to public repositories
- Do not share tokens with others
- If using a `.env` file, add it to `.gitignore`
- Consider regenerating tokens periodically

## Reference Links

- [Slack API Documentation](https://api.slack.com/docs)
- [OAuth Scopes](https://api.slack.com/scopes)
- [User Token Guide](https://api.slack.com/authentication/token-types#user)

# Session Import Feature

## Overview

Import existing claude-code sessions into claude-container environments. Useful for:
- Migrating conversations from standalone claude-code to containers
- Sharing session history between environments
- Backing up and restoring conversation context

## How It Works

Claude-code sessions are stored in `~/.claude` and contain:
- `history.jsonl` - Conversation history
- `session-env/` - Session environment state
- `plans/` - Saved plans
- `projects/` - Project-specific data

When imported, session data is copied to a Docker volume `claude-state-{SESSION_NAME}`, mounted at `/home/developer/.claude` when using `--continue`.

## Usage

### Basic Import

```bash
claude-container -s my-session --import ~/.claude
```

### Import from Backup

```bash
claude-container -s my-session --import /path/to/backup
```

### Force Overwrite

```bash
claude-container -s my-session --import ~/.claude --force
```

## Using Imported Sessions

After importing, use `--continue` to load the conversation:

```bash
claude-container -s my-session --continue
```

## How It Works

1. **Import Phase** (`--import`):
   - Validates source contains claude session files
   - Creates Docker volume: `claude-state-{SESSION_NAME}`
   - Copies session data using tar streaming

2. **Container Startup** (`-s NAME --continue`):
   - Mounts state volume at `/home/developer/.claude`
   - Claude reads `history.jsonl` to restore context

## Testing

```bash
# Create test session
mkdir -p /tmp/test-session
cat > /tmp/test-session/history.jsonl << 'EOF'
{"type":"user_message","content":"Remember: TEST123"}
{"type":"assistant_message","content":"I'll remember TEST123"}
EOF

# Import
claude-container -s test-demo --import /tmp/test-session

# Use it
claude-container -s test-demo --continue
# Ask: "What code did I tell you to remember?"
```

## Troubleshooting

### Session not loading

Use `--continue`:
```bash
claude-container -s my-session --continue  # Correct
claude-container -s my-session              # Starts fresh
```

### Overwrite existing session

```bash
claude-container -s my-session --import ~/.claude --force
```

### Verify import

```bash
docker run --rm -v claude-state-my-session:/check alpine cat /check/history.jsonl
```

## See Also

- `claude-container --sessions` - List sessions
- `claude-container -s NAME --delete` - Delete session
- `claude-container -s NAME --extract` - Extract changes as branch

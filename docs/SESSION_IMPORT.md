# Session Import Feature

## Overview

This feature allows you to import existing claude-code sessions into claude-container environments. This is useful for:
- Migrating conversations from standalone claude-code to containerized environments
- Sharing session history between different development environments
- Backing up and restoring conversation context
- Testing with pre-populated session data

## How It Works

Claude-code sessions are stored in the `~/.claude` directory (or similar) and contain:
- `history.jsonl` - Conversation history
- `session-env/` - Session environment state
- `plans/` - Saved plans
- `projects/` - Project-specific data
- `todos/` - Todo lists

When you import a session into claude-container, the session data is copied into a Docker volume named `claude-state-{SESSION_NAME}`. This volume is then automatically mounted at `/home/developer/.claude` when you start a container with that session name and the `--continue` flag.

## Usage

### Basic Import

Import a session from your local `~/.claude` directory:

```bash
./claude-container --import-session ~/.claude my-session-name
```

### Import from Backup

Import from a backup or alternative location:

```bash
./claude-container --import-session /path/to/backup/claude-session my-session-name
```

### Overwrite Existing Session

Force overwrite if the session already exists:

```bash
./claude-container --import-session ~/.claude my-session-name --force
```

## Using Imported Sessions

After importing, start a container with the session name and `--continue` flag:

```bash
./claude-container -s my-session-name --continue
```

The `--continue` flag tells Claude to resume the previous conversation from the imported session data.

## How Session Loading Works

1. **Import Phase** (`--import-session`):
   - Validates source path contains claude session files
   - Creates a Docker volume: `claude-state-{SESSION_NAME}`
   - Copies all session data into the volume using tar streaming

2. **Container Startup** (with `-s SESSION_NAME --continue`):
   - Creates/mounts the session workspace volume: `claude-session-{SESSION_NAME}`
   - Mounts the state volume: `claude-state-{SESSION_NAME}` → `/home/developer/.claude`
   - Starts Claude with `--continue` flag to load conversation history

3. **Claude Loads Context**:
   - Claude reads `/home/developer/.claude/history.jsonl`
   - Restores conversation context, plans, todos, and environment state
   - Continues conversation from where it left off

## Testing the Import

### Create a Test Session

```bash
# Create a test session directory
mkdir -p /tmp/test-session/{session-env,plans,projects,todos}

# Add a marker to the history
cat > /tmp/test-session/history.jsonl << 'EOF'
{"type":"user_message","content":"Remember this secret code: TEST123","timestamp":"2026-01-31T00:00:00.000Z"}
{"type":"assistant_message","content":"I'll remember the secret code: TEST123","timestamp":"2026-01-31T00:00:01.000Z"}
EOF

# Import the test session
./claude-container --import-session /tmp/test-session test-demo

# Verify the import
docker run --rm -v claude-state-test-demo:/check alpine cat /check/history.jsonl
```

### Test with Claude

```bash
# Start claude with the imported session
./claude-container -s test-demo --continue

# In the claude session, ask:
# "What was the secret code I told you to remember?"
#
# Expected: Claude should respond with "TEST123"
```

## Technical Details

### Docker Volumes Created

For a session named `my-session`, the following volumes are used:

- `claude-session-my-session` - Workspace (git repositories)
- `claude-state-my-session` - Session state (conversation history)
- `claude-cargo-my-session` - Rust/Cargo cache
- `claude-npm-my-session` - npm cache
- `claude-pip-my-session` - Python pip cache

The import command only creates/populates the `claude-state-*` volume. Other volumes are created automatically when you start the container.

### Session State Structure

Inside the `claude-state-{SESSION_NAME}` volume:

```
/home/developer/.claude/
├── history.jsonl          # Conversation history
├── session-env/           # Environment state
├── plans/                 # Saved plans
├── projects/              # Project-specific data
├── todos/                 # Todo lists
├── debug/                 # Debug logs
├── plugins/               # Plugin data
├── shell-snapshots/       # Shell state snapshots
└── statsig/               # Analytics data
```

### Import Implementation

The import function (`session_import` in `lib/session-mgmt.sh`):

1. Validates source path exists and contains session files
2. Creates Docker volume if it doesn't exist
3. Uses tar streaming to copy files (handles nested container scenarios):
   ```bash
   tar -cf - . | docker run -i -v {volume}:/target sh -c 'cd /target && tar -xf -'
   ```
4. Preserves file permissions and ownership
5. Reports disk usage and imported files

## Limitations

- Only session state is imported (conversation history, plans, etc.)
- Git repositories are not imported - they must be cloned separately when creating the container session
- Cache volumes (cargo, npm, pip) are not imported - they will be rebuilt as needed
- The session name must be unique (use `--force` to overwrite)

## Example Workflow

1. **Work in standalone claude-code**:
   ```bash
   claude                    # Work on a project
   # ... have a conversation, create plans, etc ...
   exit
   ```

2. **Export/backup your session**:
   ```bash
   tar -czf claude-session-backup.tar.gz -C ~/.claude .
   ```

3. **Import into container on another machine**:
   ```bash
   # Extract backup
   mkdir -p /tmp/claude-restore
   tar -xzf claude-session-backup.tar.gz -C /tmp/claude-restore

   # Import into container
   ./claude-container --import-session /tmp/claude-restore my-project
   ```

4. **Continue working in container**:
   ```bash
   ./claude-container -s my-project --continue
   # Claude will remember all previous context!
   ```

## Troubleshooting

### "Source path does not contain expected claude session files"

This warning appears if the source directory doesn't have `history.jsonl` or `session-env/`. You can continue anyway if you know the path is correct.

### "Session state already exists"

Use `--force` to overwrite:
```bash
./claude-container --import-session ~/.claude my-session --force
```

### Verify import succeeded

Check the volume contents:
```bash
docker run --rm -v claude-state-{SESSION_NAME}:/check alpine ls -lah /check/
docker run --rm -v claude-state-{SESSION_NAME}:/check alpine cat /check/history.jsonl
```

### Session not loading in container

Make sure you use the `--continue` flag:
```bash
./claude-container -s my-session --continue  # Correct
./claude-container -s my-session              # Wrong - starts fresh
```

## See Also

- `./claude-container --list-sessions` - List all sessions
- `./claude-container --delete-session <name>` - Delete a session
- `./claude-container --merge-session <name>` - Merge git changes back to source repo

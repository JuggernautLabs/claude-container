# Claude Container Architecture

## Overview

Claude Container is a **host program with an embedded agent**. The host program (`claude-container`) orchestrates isolated environments where an AI coding agent (Claude Code) operates on source code without risk to the original repositories.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host System                              │
│                                                                 │
│  ┌──────────────────┐     ┌─────────────────────────────────┐  │
│  │ claude-container │────▶│         Docker Container        │  │
│  │   (host program) │     │  ┌───────────────────────────┐  │  │
│  │                  │     │  │      Claude Code          │  │  │
│  │  • Session mgmt  │     │  │    (embedded agent)       │  │  │
│  │  • Git isolation │     │  │                           │  │  │
│  │  • Volume mgmt   │     │  │  • Code generation        │  │  │
│  │  • Auth flow     │     │  │  • File editing           │  │  │
│  │  • Extraction    │     │  │  • Command execution      │  │  │
│  └──────────────────┘     │  │  • Reasoning              │  │  │
│           │               │  └───────────────────────────┘  │  │
│           │               │              │                   │  │
│           ▼               │              ▼                   │  │
│  ┌──────────────────┐     │  ┌───────────────────────────┐  │  │
│  │  Original Repos  │     │  │    Session Volume         │  │  │
│  │  (read-only)     │     │  │    (cloned repos)         │  │  │
│  └──────────────────┘     │  └───────────────────────────┘  │  │
│                           └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Design Philosophy

### Why Embed an Agent?

Traditional development workflows require developers to context-switch between their IDE, terminal, documentation, and AI assistants. Claude Container inverts this model: **the agent becomes the primary interface**, with the developer providing high-level direction while the agent handles implementation details.

The embedded agent pattern provides:

1. **Containment**: The agent operates in an isolated environment where mistakes are recoverable
2. **Persistence**: Session state (conversation history, file changes) survives across invocations
3. **Integration**: The agent has full access to development tools (git, compilers, package managers)
4. **Safety**: Original repositories are never modified until explicitly extracted

### The Isolation Boundary

The container boundary serves as a **trust boundary** between the agent's actions and the host system:

```
Host System (trusted)          Container (agent sandbox)
─────────────────────          ─────────────────────────
Original repositories    ──▶   Cloned copies (no remote)
User credentials         ──▶   OAuth token only
Full filesystem          ──▶   Session volume only
Docker socket            ──▶   Optional, explicit opt-in
```

## Architecture Components

### 1. Host Program (`claude-container`)

The host program is a Bash application responsible for:

- **Session Management**: Creating, listing, deleting, and extracting sessions
- **Environment Setup**: Building/pulling Docker images, configuring volumes
- **Authentication**: OAuth flow, token storage, credential injection
- **Git Operations**: Cloning repos into volumes, extracting changes as branches

The host program never runs AI inference itself—it only prepares the environment and spawns the agent.

### 2. Embedded Agent (Claude Code)

Claude Code runs inside the container as an interactive CLI agent. It has:

- **Full shell access**: Can run any command available in the container
- **File system access**: Read/write access to the session volume
- **No network restrictions**: Can fetch dependencies, access APIs
- **No remote git access**: Remotes are stripped from cloned repos

The agent is unaware it's running in a container—it simply sees a development environment with source code.

### 3. Session Volumes

Docker volumes provide persistent, isolated storage:

```
claude-session-{name}   # Cloned source code
claude-state-{name}     # Claude conversation history
claude-cargo-{name}     # Rust package cache
claude-npm-{name}       # Node.js package cache
claude-pip-{name}       # Python package cache
```

Volumes persist across container restarts, enabling:
- Resume conversations with `--continue`
- Incremental work across multiple sessions
- Shared package caches to speed up builds

### 4. Git-Based Isolation

Rather than bind-mounting host directories (risky), claude-container uses git clone:

```bash
# What happens at session creation:
git clone --depth 1 /host/repo /session/repo
cd /session/repo
git remote remove origin  # Safety: prevent accidental push
git config user.email 'claude@container'
git config user.name 'Claude'
```

This provides:
- **Snapshot isolation**: Session starts from a known state
- **Change tracking**: All modifications are git commits
- **Safe extraction**: Changes become a branch, reviewed before merge

## Session Lifecycle

### 1. Create

```bash
claude-container -s myfeature
```

The host program:
1. Creates Docker volumes for session and state
2. Clones source repository into session volume
3. Strips git remotes (safety measure)
4. Starts container with Claude Code

### 2. Work

Inside the container, the agent:
- Receives instructions via natural language
- Reads and modifies source files
- Runs builds, tests, linters
- Commits changes to local git

The developer can:
- Guide the agent with high-level goals
- Review changes in real-time
- Exit and resume later with `--continue`

### 3. Extract

```bash
claude-container -s myfeature --extract
```

The host program:
1. Extracts session volume to temporary directory
2. Compares session HEAD to original repo HEAD
3. Creates a branch in the original repo (if changes exist)
4. Reports commit count and files changed

```
✓ myproject → branch 'myfeature' (3 commit(s), 7 file(s))

To see changes:  git log main..myfeature
Checkout:        git checkout myfeature
Merge:           git merge myfeature
```

### 4. Integrate

Using standard git workflow:
```bash
git checkout myfeature
git rebase main
git checkout main
git merge myfeature
git push
```

The developer maintains full control over what gets merged.

## Multi-Project Sessions

For monorepo-like workflows, a single session can contain multiple repositories:

```yaml
# .claude-projects.yml
version: "1"
main: backend/api
projects:
  backend/api:
    path: ~/dev/api
  backend/workers:
    path: ~/dev/workers
  frontend/web:
    path: ~/dev/webapp
```

The agent sees a unified workspace:
```
/session/
├── backend/
│   ├── api/          # Main project (initial working directory)
│   └── workers/
└── frontend/
    └── web/
```

Extraction creates branches in each original repository that had changes.

## Security Model

### What the Agent Can Do

- Read/write files in session volume
- Execute arbitrary commands in container
- Install packages via apt/npm/pip/cargo
- Make network requests (fetch dependencies, APIs)
- Access Docker socket (only if `--docker` flag provided)

### What the Agent Cannot Do

- Modify original host repositories
- Push to git remotes (remotes are stripped)
- Access host filesystem outside mounted volumes
- Access host credentials beyond the OAuth token
- Persist changes without explicit extraction

### Trust Assumptions

1. **Claude Code is trusted** to not be intentionally malicious
2. **Container isolation is sufficient** for the threat model (dev workstation, not production)
3. **Git history is the audit log** for all agent modifications
4. **Human review before merge** catches any problematic changes

## Comparison to Alternatives

| Approach | Isolation | Persistence | Agent Integration |
|----------|-----------|-------------|-------------------|
| Direct host access | None | Full | Risky |
| VM-based sandbox | Strong | Complex | Slow startup |
| Bind-mount container | Weak | Full | Changes immediate |
| **Git-session container** | **Medium** | **Branch-based** | **Review before merge** |

Claude Container optimizes for the **development workflow** where:
- Iteration speed matters 
- Changes need review before integration
- Multiple experimental branches are common
- Package caches should be reusable

## Future Directions

Potential enhancements to the embedded agent architecture:

1. **Agent Checkpointing**: Save/restore agent state at specific points
2. **Parallel Sessions**: Run multiple agents on different features
3. **Agent Handoff**: Transfer context between different AI models
4. **Structured Output**: Agent produces PRs, tickets, or documentation
5. **Supervisory Agents**: Meta-agent that spawns task-specific sub-agents

The embedded agent pattern scales to more sophisticated orchestration while maintaining the core principle: **agents operate in isolated environments with explicit extraction points**.

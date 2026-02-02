# Clonk: Remote Claude Code Hub

## Overview

Clonk is a lightweight, externally-exposable service that runs Claude Code remotely. Built on Substrate's plugin architecture, it provides authenticated API access to Claude Code sessions over HTTP/SSE and WebSocket transports.

**Core idea**: Run Claude Code in a controlled environment and expose it as an API, enabling:
- Remote development workflows
- CI/CD integration (claude-build)
- Multi-tenant Claude Code hosting
- Programmatic access to Claude Code capabilities

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                            Clonk                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Gateway Layer                             │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │
│  │  │   Auth      │  │   Rate      │  │   Request           │  │   │
│  │  │   (API Key) │  │   Limiting  │  │   Validation        │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                   Transport Layer                            │   │
│  │  ┌─────────────────┐  ┌─────────────────┐                   │   │
│  │  │   HTTP/SSE      │  │   WebSocket     │                   │   │
│  │  │   :4445/mcp     │  │   :4444         │                   │   │
│  │  └─────────────────┘  └─────────────────┘                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                   Substrate Core                             │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │
│  │  │   Plexus    │  │   Router    │  │   Schema Registry   │  │   │
│  │  │   (Hub)     │  │             │  │                     │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                   Activations (Plugins)                      │   │
│  │                                                              │   │
│  │  ┌─────────────────────────────────────────────────────┐    │   │
│  │  │                  claudecode                          │    │   │
│  │  │  - create(name, working_dir, model, system_prompt)  │    │   │
│  │  │  - chat(name, prompt, ephemeral) [streaming]        │    │   │
│  │  │  - get(name)                                        │    │   │
│  │  │  - list()                                           │    │   │
│  │  │  - fork(name, snapshot_id)                          │    │   │
│  │  │  - delete(name)                                     │    │   │
│  │  └─────────────────────────────────────────────────────┘    │   │
│  │                                                              │   │
│  │  ┌─────────────────────────────────────────────────────┐    │   │
│  │  │                    arbor                             │    │   │
│  │  │  - tree_create, tree_get, tree_list                 │    │   │
│  │  │  - node_create, node_get, node_children             │    │   │
│  │  │  - context_*, position_*                            │    │   │
│  │  └─────────────────────────────────────────────────────┘    │   │
│  │                                                              │   │
│  │  ┌─────────────────────────────────────────────────────┐    │   │
│  │  │                   gitsync                            │    │   │
│  │  │  - register(path, remote, branch)                   │    │   │
│  │  │  - sync(path) / sync_all()                          │    │   │
│  │  │  - diff(path)                                       │    │   │
│  │  │  - create_pr(path, title, body)                     │    │   │
│  │  └─────────────────────────────────────────────────────┘    │   │
│  │                                                              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                   Storage Layer                              │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │
│  │  │  arbor.db   │  │ claudecode  │  │   workspaces/       │  │   │
│  │  │  (trees)    │  │    .db      │  │   (git repos)       │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Gateway Layer

Handles authentication, authorization, and request validation before requests reach Substrate.

#### Authentication

```yaml
# clonk.yaml
auth:
  # API key authentication
  api_keys:
    - id: "key_prod_abc123"
      secret_hash: "sha256:..."
      scopes: ["claudecode:*", "arbor:read"]
      rate_limit: 100/min

    - id: "key_ci_xyz789"
      secret_hash: "sha256:..."
      scopes: ["claudecode:chat", "gitsync:*"]
      rate_limit: 1000/min

  # Optional: JWT for user sessions
  jwt:
    issuer: "https://auth.example.com"
    audience: "clonk"
    jwks_uri: "https://auth.example.com/.well-known/jwks.json"
```

#### Scopes

| Scope | Permissions |
|-------|-------------|
| `claudecode:*` | Full Claude Code access |
| `claudecode:chat` | Chat only (no create/delete) |
| `claudecode:read` | List and get sessions |
| `arbor:*` | Full tree manipulation |
| `arbor:read` | Read-only tree access |
| `gitsync:*` | Git sync operations |
| `gitsync:read` | Diff only, no push |

### 2. Transport Layer

Inherited from Substrate with optional TLS termination.

#### HTTP/SSE (MCP-compatible)

```bash
# Create session
curl -X POST https://clonk.example.com/mcp \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"claudecode.create","params":{"name":"session1","working_dir":"/workspace"},"id":1}'

# Chat (streaming via SSE)
curl -N https://clonk.example.com/mcp \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"claudecode.chat","params":{"name":"session1","prompt":"List files"},"id":2}'
```

#### WebSocket

```javascript
const ws = new WebSocket('wss://clonk.example.com/ws');

ws.onopen = () => {
  // Authenticate first
  ws.send(JSON.stringify({
    jsonrpc: "2.0",
    method: "auth.authenticate",
    params: { api_key: API_KEY },
    id: 0
  }));
};

// Then use normally
ws.send(JSON.stringify({
  jsonrpc: "2.0",
  method: "claudecode.chat",
  params: { name: "session1", prompt: "Hello" },
  id: 1
}));
```

### 3. Activations

#### claudecode

Core Claude Code session management. Wraps the Claude CLI binary.

```rust
pub struct ClaudeCode {
    storage: Arc<ClaudeCodeStorage>,  // SQLite: sessions, messages
    executor: ClaudeCodeExecutor,      // Spawns claude binary
    arbor: Arc<Arbor>,                 // Conversation tree storage
}

// Methods exposed via JSON-RPC
impl ClaudeCode {
    /// Create a new Claude Code session
    async fn create(&self,
        name: String,
        working_dir: PathBuf,
        model: Option<Model>,        // sonnet, opus, haiku
        system_prompt: Option<String>
    ) -> CreateResult;

    /// Send a message and stream responses
    #[streaming]
    async fn chat(&self,
        name: String,
        prompt: String,
        ephemeral: Option<bool>      // Don't persist to history
    ) -> impl Stream<Item = ChatEvent>;

    /// Get session details
    async fn get(&self, name: String) -> Session;

    /// List all sessions
    async fn list(&self) -> Vec<SessionSummary>;

    /// Fork session at a specific point
    async fn fork(&self,
        name: String,
        snapshot_id: String
    ) -> Session;

    /// Delete a session
    async fn delete(&self, name: String) -> bool;
}
```

#### arbor

Conversation tree storage. Enables branching, forking, and context management.

```rust
// Key methods
impl Arbor {
    async fn tree_create(&self, name: String) -> TreeId;
    async fn tree_get(&self, id: TreeId) -> Tree;

    async fn node_create(&self,
        tree_id: TreeId,
        parent_id: Option<NodeId>,
        content: Value
    ) -> NodeId;

    async fn node_children(&self, node_id: NodeId) -> Vec<Node>;
    async fn node_ancestors(&self, node_id: NodeId) -> Vec<Node>;
}
```

#### gitsync (new)

Manages workspace-to-repository mappings and synchronization.

```rust
pub struct GitSync {
    workspaces: HashMap<PathBuf, WorkspaceConfig>,
}

pub struct WorkspaceConfig {
    path: PathBuf,
    remote: String,           // git@github.com:org/repo.git
    branch: String,           // main, or feature branch
    auto_commit: bool,        // Commit on each chat completion
    auto_push: bool,          // Push after commit
}

impl GitSync {
    /// Register a workspace mapping
    async fn register(&self,
        path: PathBuf,
        remote: String,
        branch: String
    ) -> WorkspaceConfig;

    /// Get diff for a workspace
    async fn diff(&self, path: PathBuf) -> String;

    /// Sync workspace to remote (commit + push)
    async fn sync(&self,
        path: PathBuf,
        message: Option<String>
    ) -> SyncResult;

    /// Sync all registered workspaces
    async fn sync_all(&self) -> Vec<SyncResult>;

    /// Create a pull request
    async fn create_pr(&self,
        path: PathBuf,
        title: String,
        body: String,
        base: Option<String>     // Default: main
    ) -> PullRequest;
}
```

### 4. Storage Layer

#### SQLite Databases

| Database | Purpose |
|----------|---------|
| `arbor.db` | Conversation trees and nodes |
| `claudecode.db` | Sessions, messages, tool calls |
| `clonk.db` | API keys, rate limits, audit log |

#### Workspace Storage

```
/var/clonk/workspaces/
├── {session_id}/
│   ├── .git/
│   ├── src/
│   └── ...
└── shared/
    └── {workspace_name}/
```

## Deployment Modes

### 1. Single-tenant (Self-hosted)

Run Clonk for personal or team use.

```bash
# Docker
docker run -d \
  -p 4444:4444 \
  -p 4445:4445 \
  -v clonk-data:/var/clonk \
  -e CLAUDE_CODE_OAUTH_TOKEN=$TOKEN \
  ghcr.io/hypermemetic/clonk:latest

# Or with docker-compose
version: '3.8'
services:
  clonk:
    image: ghcr.io/hypermemetic/clonk:latest
    ports:
      - "4444:4444"
      - "4445:4445"
    volumes:
      - clonk-data:/var/clonk
      - ./clonk.yaml:/etc/clonk/config.yaml
    environment:
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
```

### 2. Multi-tenant (Platform)

Run Clonk as a service for multiple users/organizations.

```
┌─────────────────────────────────────────────────────────────┐
│                      Load Balancer                          │
│                    (TLS termination)                        │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│   Clonk Pod   │   │   Clonk Pod   │   │   Clonk Pod   │
│   (worker 1)  │   │   (worker 2)  │   │   (worker 3)  │
└───────────────┘   └───────────────┘   └───────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                    ┌─────────────────┐
                    │   Shared State  │
                    │   (Redis/PG)    │
                    └─────────────────┘
```

**Considerations:**
- Session affinity for WebSocket connections
- Shared session storage (Redis for ephemeral, Postgres for persistent)
- Per-tenant rate limiting
- Usage metering and billing hooks

### 3. Embedded (claude-build)

Clonk runs inside a build container, controlled by claude-build.

```
┌──────────────────────────────────────────────────────────────┐
│                     Build Container                          │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                      Clonk                              │ │
│  │  - Injected as entrypoint                              │ │
│  │  - Workspace mounted at /workspace                     │ │
│  │  - Git remotes configured by claude-build              │ │
│  └────────────────────────────────────────────────────────┘ │
│                              │                               │
│                              ▼                               │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    /workspace                           │ │
│  │  - Source code (mounted or cloned)                     │ │
│  │  - Build artifacts                                     │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
        │                                        │
        │ stdio (JSON-RPC)                       │ git push
        ▼                                        ▼
┌───────────────┐                      ┌───────────────────┐
│  claude-build │                      │   Git Remote      │
│  orchestrator │                      │   (GitHub, etc)   │
└───────────────┘                      └───────────────────┘
```

## Configuration

### clonk.yaml

```yaml
# Clonk configuration
version: "1"

# Server settings
server:
  host: "0.0.0.0"
  websocket_port: 4444
  http_port: 4445

  # TLS (optional, usually handled by reverse proxy)
  tls:
    enabled: false
    cert_path: /etc/clonk/tls/cert.pem
    key_path: /etc/clonk/tls/key.pem

# Authentication
auth:
  # Disable for embedded/single-user mode
  enabled: true

  api_keys:
    - id: "default"
      secret_hash: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      scopes: ["*"]

# Claude Code settings
claudecode:
  # Path to claude binary (auto-detected if not specified)
  binary_path: null

  # Default model for new sessions
  default_model: "sonnet"

  # OAuth token (can also use CLAUDE_CODE_OAUTH_TOKEN env var)
  oauth_token: null

  # Session defaults
  session:
    timeout: 3600          # Session timeout in seconds
    max_concurrent: 10     # Max concurrent sessions
    working_dir: "/workspace"

# Storage
storage:
  data_dir: "/var/clonk"

  # Database connection (for multi-tenant)
  # database_url: "postgres://user:pass@host/clonk"

# Workspaces (for gitsync)
workspaces:
  # Predefined workspace mappings
  mappings:
    - path: "/workspace"
      remote: "git@github.com:org/repo.git"
      branch: "main"

  # Auto-discover by scanning for .git directories
  auto_discover: true

  # Organizations to match (for auto-discovery)
  allowed_orgs:
    - "hypermemetic"
    - "juggernautlabs"

# Logging
logging:
  level: "info"
  format: "json"  # or "pretty"

# Metrics (optional)
metrics:
  enabled: true
  port: 9090
```

## API Reference

### JSON-RPC Methods

#### claudecode.create

Create a new Claude Code session.

```json
// Request
{
  "jsonrpc": "2.0",
  "method": "claudecode.create",
  "params": {
    "name": "feature-auth",
    "working_dir": "/workspace",
    "model": "sonnet",
    "system_prompt": "You are helping implement authentication."
  },
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "name": "feature-auth",
    "id": "sess_abc123",
    "created_at": "2025-01-16T12:00:00Z",
    "working_dir": "/workspace",
    "model": "sonnet"
  },
  "id": 1
}
```

#### claudecode.chat

Send a message and receive streaming response.

```json
// Request
{
  "jsonrpc": "2.0",
  "method": "claudecode.chat",
  "params": {
    "name": "feature-auth",
    "prompt": "Add JWT validation middleware"
  },
  "id": 2
}

// Response (subscription)
{"jsonrpc": "2.0", "result": "sub_12345", "id": 2}

// Streaming events
{"jsonrpc": "2.0", "method": "subscription", "params": {
  "subscription": "sub_12345",
  "result": {
    "type": "assistant_message",
    "content": "I'll add JWT validation..."
  }
}}

{"jsonrpc": "2.0", "method": "subscription", "params": {
  "subscription": "sub_12345",
  "result": {
    "type": "tool_use",
    "tool": "write",
    "input": {"path": "/workspace/src/middleware/jwt.ts", "content": "..."}
  }
}}

{"jsonrpc": "2.0", "method": "subscription", "params": {
  "subscription": "sub_12345",
  "result": {"type": "done"}
}}
```

#### gitsync.sync

Sync workspace changes to remote.

```json
// Request
{
  "jsonrpc": "2.0",
  "method": "gitsync.sync",
  "params": {
    "path": "/workspace",
    "message": "Add JWT validation middleware"
  },
  "id": 3
}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "status": "pushed",
    "commit": "abc123f",
    "branch": "claude/feature-auth",
    "remote": "origin",
    "files_changed": 3,
    "insertions": 45,
    "deletions": 2
  },
  "id": 3
}
```

## Security Considerations

### 1. Code Execution

Claude Code can execute arbitrary commands. Mitigations:

- **Container isolation**: Run in unprivileged containers
- **Network policies**: Restrict outbound access
- **Resource limits**: CPU, memory, disk quotas
- **Audit logging**: Log all tool invocations

### 2. Token Security

- OAuth tokens stored encrypted at rest
- Tokens passed via file mounts, not env vars
- Token rotation support

### 3. Git Operations

- **Remote stripping**: Option to remove remotes (like claude-container)
- **Push restrictions**: Allowlist of permitted remotes
- **Branch protection**: Only push to feature branches, never main

### 4. Multi-tenant Isolation

- Separate SQLite databases per tenant
- Workspace isolation via containers or namespaces
- Rate limiting per API key

## Integration with claude-build

Clonk serves as the runtime for claude-build:

```bash
# claude-build workflow
claude-build \
  --image node:20 \
  --workspace ./myproject \
  --sync-to origin/claude-build-output

# Internally:
# 1. claude-build starts container with Clonk as entrypoint
# 2. Mounts workspace with git history
# 3. Configures gitsync with remote mapping
# 4. Connects to Clonk via stdio JSON-RPC
# 5. Sends prompts, receives streaming responses
# 6. On exit, calls gitsync.sync_all()
# 7. Extracts artifacts if specified
```

## Roadmap

### Phase 1: Core (MVP)

- [ ] Extract Clonk from Substrate
- [ ] Add authentication layer
- [ ] Implement gitsync activation
- [ ] Docker image with minimal dependencies

### Phase 2: Production Ready

- [ ] TLS support
- [ ] Rate limiting
- [ ] Audit logging
- [ ] Metrics/observability
- [ ] Multi-tenant storage

### Phase 3: Platform Features

- [ ] Session sharing/collaboration
- [ ] Webhook notifications
- [ ] Custom tool plugins
- [ ] Usage metering

## Appendix: Name Origin

**Clonk** (noun): The sound of something solid connecting.

In this context: the solid connection between remote clients and Claude Code's capabilities.

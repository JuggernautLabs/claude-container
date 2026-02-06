#!/usr/bin/env bash
# Test script for multi-project session support in claude-container
#
# This script creates test repositories, tests multi-project sessions,
# and verifies extraction functionality.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# Configuration
# Use $HOME instead of /tmp because Colima/Docker on macOS only mounts $HOME by default
TEST_DIR="$HOME/.cache/claude-container-test-$$"
SESSION_NAME="test-multi-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONTAINER="$SCRIPT_DIR/../claude-container"

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if [[ ! -f "$CLAUDE_CONTAINER" ]]; then
        error "claude-container script not found at: $CLAUDE_CONTAINER"
        exit 1
    fi

    if ! command -v yq &>/dev/null && ! (command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null 2>&1); then
        error "No YAML parser found (need yq or python3 with PyYAML)"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        error "Docker not running"
        exit 1
    fi

    success "All prerequisites met"
}

# Create test repositories
create_test_repos() {
    info "Creating test repositories in: $TEST_DIR"
    mkdir -p "$TEST_DIR"

    # Create repo1 (frontend)
    mkdir -p "$TEST_DIR/frontend"
    cd "$TEST_DIR/frontend"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    cat > README.md << 'EOF'
# Frontend Project
This is a test frontend repository.
EOF
    cat > package.json << 'EOF'
{
  "name": "frontend",
  "version": "1.0.0"
}
EOF
    git add .
    git commit -q -m "initial frontend commit"
    success "Created frontend repo"

    # Create repo2 (backend)
    mkdir -p "$TEST_DIR/backend"
    cd "$TEST_DIR/backend"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    cat > README.md << 'EOF'
# Backend Project
This is a test backend repository.
EOF
    cat > main.go << 'EOF'
package main

func main() {
    println("Hello from backend")
}
EOF
    git add .
    git commit -q -m "initial backend commit"
    success "Created backend repo"

    # Create repo3 (shared)
    mkdir -p "$TEST_DIR/shared"
    cd "$TEST_DIR/shared"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    cat > README.md << 'EOF'
# Shared Library
Shared code between frontend and backend.
EOF
    cat > types.ts << 'EOF'
export interface User {
    id: string;
    name: string;
}
EOF
    git add .
    git commit -q -m "initial shared commit"
    success "Created shared repo"
}

# Create multi-project config
create_config() {
    info "Creating .claude-projects.yml config..."
    cd "$TEST_DIR"

    cat > .claude-projects.yml << EOF
version: "1"
projects:
  frontend:
    path: $TEST_DIR/frontend
  backend:
    path: $TEST_DIR/backend
  shared:
    path: $TEST_DIR/shared
EOF

    success "Config created"
    echo "Config contents:"
    cat .claude-projects.yml | sed 's/^/  /'
}

# Test: Create multi-project session
test_create_session() {
    info "TEST 1: Creating multi-project session..."
    cd "$TEST_DIR"

    # This should detect the config and create a multi-project session
    # Use --no-run to create session without launching the container
    "$CLAUDE_CONTAINER" -s "$SESSION_NAME" --no-run -C .claude-projects.yml 2>&1 | tee /tmp/create-output.log

    if grep -qi "Multi-project\|session created\|3 projects" /tmp/create-output.log; then
        success "Multi-project session created"
    else
        error "Multi-project session creation failed"
        cat /tmp/create-output.log
        return 1
    fi

    # Verify the session volume was created
    if docker volume inspect "claude-session-$SESSION_NAME" &>/dev/null; then
        success "Session volume created"
    else
        error "Session volume was NOT created"
        return 1
    fi

    # Verify projects are cloned inside the volume
    info "Verifying projects in session volume..."
    local projects=$(docker run --rm \
        -v "claude-session-$SESSION_NAME:/session:ro" \
        alpine ls -1a /session 2>/dev/null || echo "")

    if echo "$projects" | grep -q "frontend"; then
        success "  ✓ frontend cloned"
    else
        error "  ✗ frontend NOT found"
        return 1
    fi

    if echo "$projects" | grep -q "backend"; then
        success "  ✓ backend cloned"
    else
        error "  ✗ backend NOT found"
        return 1
    fi

    if echo "$projects" | grep -q "shared"; then
        success "  ✓ shared cloned"
    else
        error "  ✗ shared NOT found"
        return 1
    fi

    if echo "$projects" | grep -q ".claude-projects.yml"; then
        success "  ✓ config stored in volume"
    else
        error "  ✗ config NOT stored"
        return 1
    fi
}

# Test: Make changes in the session
test_make_changes() {
    info "TEST 2: Making changes in session..."

    local git_image="ghcr.io/hypermemetic/claude-container:latest"

    # Add a commit to frontend
    docker run --rm \
        -v "claude-session-$SESSION_NAME:/workspace" \
        -w /workspace/frontend \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory /workspace/frontend
            git config user.email 'test@example.com'
            git config user.name 'Test User'
            echo 'export const API_URL = \"http://localhost:3000\";' > config.ts
            git add config.ts
            git commit -m 'add API config'
        " &>/dev/null

    success "  ✓ Added commit to frontend"

    # Add a commit to backend
    docker run --rm \
        -v "claude-session-$SESSION_NAME:/workspace" \
        -w /workspace/backend \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory /workspace/backend
            git config user.email 'test@example.com'
            git config user.name 'Test User'
            echo 'const PORT = 3000' > config.go
            git add config.go
            git commit -m 'add server config'
        " &>/dev/null

    success "  ✓ Added commit to backend"

    # Leave shared unchanged
    info "  → shared left unchanged (for testing)"
}

# Test: Extract session as branches
test_extract() {
    info "TEST 3: Extracting session as branches..."
    cd "$TEST_DIR"

    local extract_output=$("$CLAUDE_CONTAINER" -s "$SESSION_NAME" --extract --force 2>&1)

    if echo "$extract_output" | grep -qi "branch.*$SESSION_NAME\|created"; then
        success "  ✓ Extraction reported success"
    else
        error "  ✗ Extraction failed"
        echo "$extract_output"
        return 1
    fi

    # Verify branch was created in frontend
    cd "$TEST_DIR/frontend"
    if git show-ref --verify --quiet "refs/heads/$SESSION_NAME" 2>/dev/null; then
        success "  ✓ Branch '$SESSION_NAME' created in frontend"
    else
        error "  ✗ Branch NOT created in frontend"
        return 1
    fi

    # Verify the commit is on the branch
    if git log "$SESSION_NAME" --oneline | grep -q "add API config"; then
        success "  ✓ Frontend commit found on branch"
    else
        error "  ✗ Frontend commit NOT on branch"
        return 1
    fi

    # Verify branch was created in backend
    cd "$TEST_DIR/backend"
    if git show-ref --verify --quiet "refs/heads/$SESSION_NAME" 2>/dev/null; then
        success "  ✓ Branch '$SESSION_NAME' created in backend"
    else
        error "  ✗ Branch NOT created in backend"
        return 1
    fi

    # Verify the commit is on the branch
    if git log "$SESSION_NAME" --oneline | grep -q "add server config"; then
        success "  ✓ Backend commit found on branch"
    else
        error "  ✗ Backend commit NOT on branch"
        return 1
    fi

    # Shared should not have a branch (no changes)
    cd "$TEST_DIR/shared"
    if ! git show-ref --verify --quiet "refs/heads/$SESSION_NAME" 2>/dev/null; then
        success "  ✓ Shared has no branch (as expected, no changes)"
    else
        info "  → Shared has branch (extraction included unchanged project)"
    fi
}

# Test: Verify branch contents
test_verify_branches() {
    info "TEST 4: Verifying branch contents..."

    # Check frontend branch has config.ts
    cd "$TEST_DIR/frontend"
    git checkout -q "$SESSION_NAME"
    if [[ -f config.ts ]]; then
        success "  ✓ Frontend config.ts exists on branch"
    else
        error "  ✗ Frontend config.ts NOT found"
        return 1
    fi
    git checkout -q master

    # Check backend branch has config.go
    cd "$TEST_DIR/backend"
    git checkout -q "$SESSION_NAME"
    if [[ -f config.go ]]; then
        success "  ✓ Backend config.go exists on branch"
    else
        error "  ✗ Backend config.go NOT found"
        return 1
    fi
    git checkout -q master
}

# Cleanup
cleanup() {
    info "Cleaning up..."

    # Delete session volumes
    if docker volume inspect "claude-session-$SESSION_NAME" &>/dev/null; then
        docker volume rm "claude-session-$SESSION_NAME" &>/dev/null || true
    fi

    if docker volume inspect "claude-state-$SESSION_NAME" &>/dev/null; then
        docker volume rm "claude-state-$SESSION_NAME" &>/dev/null || true
    fi

    # Delete test directory
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi

    success "Cleanup complete"
}

# Main test flow
main() {
    echo "======================================"
    echo "Multi-Project Session Test Suite"
    echo "======================================"
    echo ""

    trap cleanup EXIT

    check_prerequisites
    echo ""

    create_test_repos
    echo ""

    create_config
    echo ""

    test_create_session
    echo ""

    test_make_changes
    echo ""

    test_extract
    echo ""

    test_verify_branches
    echo ""

    echo "======================================"
    success "ALL TESTS PASSED! 🎉"
    echo "======================================"
}

main "$@"

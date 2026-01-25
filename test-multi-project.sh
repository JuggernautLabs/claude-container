#!/usr/bin/env bash
# Test script for multi-project session support in claude-container
#
# This script creates test repositories, tests multi-project sessions,
# and verifies diff/merge functionality.

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
TEST_DIR="/tmp/claude-container-test-$$"
SESSION_NAME="test-multi-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONTAINER="$SCRIPT_DIR/claude-container"

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if [[ ! -f "$CLAUDE_CONTAINER" ]]; then
        error "claude-container script not found at: $CLAUDE_CONTAINER"
        exit 1
    fi

    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        error "CLAUDE_CODE_OAUTH_TOKEN not set"
        echo "Run: export CLAUDE_CODE_OAUTH_TOKEN=\$(security find-generic-password -s \"claude-code-token\" -a \"$(whoami)\" -w)"
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
    path: ./frontend
  backend:
    path: ./backend
  shared:
    path: ./shared
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
    if "$CLAUDE_CONTAINER" --git-session "$SESSION_NAME" <<< "exit" 2>&1 | tee /tmp/create-output.log | grep -q "Multi-project config detected"; then
        success "Multi-project config was detected"
    else
        error "Multi-project config was NOT detected"
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
        alpine ls -1 /session 2>/dev/null || echo "")

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

    # Add a commit to frontend
    docker run --rm \
        -v "claude-session-$SESSION_NAME:/workspace" \
        -w /workspace/frontend \
        alpine/git sh -c "
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
        alpine/git sh -c "
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

# Test: Diff session (summary)
test_diff_summary() {
    info "TEST 3: Testing diff (summary mode)..."
    cd "$TEST_DIR"

    local diff_output=$("$CLAUDE_CONTAINER" --diff-session "$SESSION_NAME" 2>&1)

    if echo "$diff_output" | grep -q "Multi-project session"; then
        success "  ✓ Multi-project session detected"
    else
        error "  ✗ Not recognized as multi-project"
        echo "$diff_output"
        return 1
    fi

    if echo "$diff_output" | grep -q "frontend (1 commits)"; then
        success "  ✓ Frontend shows 1 commit"
    else
        error "  ✗ Frontend commit count wrong"
        echo "$diff_output"
        return 1
    fi

    if echo "$diff_output" | grep -q "backend (1 commits)"; then
        success "  ✓ Backend shows 1 commit"
    else
        error "  ✗ Backend commit count wrong"
        echo "$diff_output"
        return 1
    fi

    if echo "$diff_output" | grep -q "shared (0 commits)"; then
        success "  ✓ Shared shows 0 commits"
    else
        error "  ✗ Shared commit count wrong"
        echo "$diff_output"
        return 1
    fi

    echo ""
    echo "Diff output:"
    echo "$diff_output" | sed 's/^/  /'
}

# Test: Diff session (specific project)
test_diff_project() {
    info "TEST 4: Testing diff (specific project)..."
    cd "$TEST_DIR"

    local diff_output=$("$CLAUDE_CONTAINER" --diff-session "$SESSION_NAME" frontend 2>&1)

    if echo "$diff_output" | grep -q "add API config"; then
        success "  ✓ Frontend commit message shown"
    else
        error "  ✗ Frontend commit message not found"
        echo "$diff_output"
        return 1
    fi

    if echo "$diff_output" | grep -q "config.ts"; then
        success "  ✓ Changed file listed"
    else
        warn "  ! Changed file not listed (may be expected)"
    fi
}

# Test: Merge session
test_merge() {
    info "TEST 5: Testing merge..."
    cd "$TEST_DIR"

    # Run merge with --auto flag to skip prompts
    local merge_output=$("$CLAUDE_CONTAINER" --merge-session "$SESSION_NAME" --auto 2>&1)

    if echo "$merge_output" | grep -q "Merging multi-project session"; then
        success "  ✓ Multi-project merge detected"
    else
        error "  ✗ Not recognized as multi-project merge"
        echo "$merge_output"
        return 1
    fi

    # Verify frontend got the commit
    cd "$TEST_DIR/frontend"
    if git log --oneline | grep -q "add API config"; then
        success "  ✓ Frontend commit merged"
    else
        error "  ✗ Frontend commit NOT merged"
        git log --oneline
        return 1
    fi

    if [[ -f config.ts ]]; then
        success "  ✓ Frontend file exists"
    else
        error "  ✗ Frontend file NOT found"
        return 1
    fi

    # Verify backend got the commit
    cd "$TEST_DIR/backend"
    if git log --oneline | grep -q "add server config"; then
        success "  ✓ Backend commit merged"
    else
        error "  ✗ Backend commit NOT merged"
        git log --oneline
        return 1
    fi

    if [[ -f config.go ]]; then
        success "  ✓ Backend file exists"
    else
        error "  ✗ Backend file NOT found"
        return 1
    fi

    # Verify shared is unchanged
    cd "$TEST_DIR/shared"
    local commit_count=$(git rev-list --count HEAD)
    if [[ "$commit_count" -eq 1 ]]; then
        success "  ✓ Shared unchanged (still 1 commit)"
    else
        error "  ✗ Shared has unexpected commits"
        git log --oneline
        return 1
    fi
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

    test_diff_summary
    echo ""

    test_diff_project
    echo ""

    test_merge
    echo ""

    echo "======================================"
    success "ALL TESTS PASSED! 🎉"
    echo "======================================"
}

main "$@"

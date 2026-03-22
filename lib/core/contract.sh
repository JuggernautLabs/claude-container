#!/usr/bin/env bash
# Contract helpers — logging, confirmation, guards, structured output.
# All logging goes to stderr. stdout is for data only.
# Source this in every standalone script.

# Colors (only if stderr is a terminal)
if [[ -t 2 ]]; then
    _CC_RED='\033[0;31m'
    _CC_GREEN='\033[0;32m'
    _CC_YELLOW='\033[1;33m'
    _CC_BLUE='\033[0;34m'
    _CC_DIM='\033[2m'
    _CC_NC='\033[0m'
else
    _CC_RED='' _CC_GREEN='' _CC_YELLOW='' _CC_BLUE='' _CC_DIM='' _CC_NC=''
fi

# Logging (always stderr)
cc_info()  { echo -e "${_CC_BLUE}→${_CC_NC} $*" >&2; }
cc_ok()    { echo -e "${_CC_GREEN}✓${_CC_NC} $*" >&2; }
cc_warn()  { echo -e "${_CC_YELLOW}⚠${_CC_NC} $*" >&2; }
cc_error() { echo -e "${_CC_RED}✗${_CC_NC} $*" >&2; }
cc_note()  { echo -e "${_CC_DIM}· $*${_CC_NC}" >&2; }

# Horizontal rule
cc_rule() {
    local label="${1:-}" width=50
    if [[ -n "$label" ]]; then
        local pad=$(( (width - ${#label} - 2) / 2 ))
        local left="" right=""
        for ((i=0; i<pad; i++)); do left+="─"; done
        for ((i=0; i<pad; i++)); do right+="─"; done
        while [[ $(( ${#left} + ${#label} + ${#right} + 2 )) -lt $width ]]; do right+="─"; done
        echo -e "${_CC_DIM}${left} ${_CC_NC}${label}${_CC_DIM} ${right}${_CC_NC}" >&2
    else
        local line=""
        for ((i=0; i<width; i++)); do line+="─"; done
        echo -e "${_CC_DIM}${line}${_CC_NC}" >&2
    fi
}

# Confirmation — returns 0 if confirmed, 1 if denied
# Non-interactive (no tty): always returns 1 unless CC_FORCE=1
cc_confirm() {
    local prompt="$1"

    if [[ "${CC_FORCE:-}" == "1" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        cc_warn "$prompt (non-interactive — use --force to proceed)"
        return 1
    fi

    printf "${_CC_YELLOW}⚠${_CC_NC} %s [y/N] " "$prompt" >&2
    local answer
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Destructive confirmation — extra warning, always shows what will be destroyed
cc_confirm_destructive() {
    local description="$1"
    shift
    local -a details=("$@")

    echo "" >&2
    cc_warn "$description"
    for detail in "${details[@]}"; do
        echo -e "  ${_CC_DIM}· $detail${_CC_NC}" >&2
    done

    if [[ "${CC_FORCE:-}" == "1" ]]; then
        cc_info "Proceeding (--force)"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        cc_error "Blocked: destructive operation in non-interactive mode"
        cc_note "Use --force to proceed"
        return 1
    fi

    echo "" >&2
    printf "Proceed? [y/N] " >&2
    local answer
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) echo "Aborted" >&2; return 1 ;;
    esac
}

# Guards
cc_require_docker() {
    command -v docker &>/dev/null || { cc_error "Docker not found"; return 1; }
    docker info &>/dev/null || { cc_error "Docker not running"; return 1; }
}

cc_require_volume() {
    docker volume inspect "$1" &>/dev/null || { cc_error "Volume not found: $1"; return 1; }
}

cc_require_container() {
    docker ps -aq --filter "name=^${1}$" 2>/dev/null | grep -q . || { cc_error "Container not found: $1"; return 1; }
}

cc_require_image() {
    docker image inspect "$1" &>/dev/null || { cc_error "Image not found: $1"; return 1; }
}

# Result file I/O (from utils.sh — per-repo key=value files)
cc_result_set() {
    local dir="$1" repo="$2" key="$3" val="$4"
    echo "${key}=${val}" >> "${dir}/${repo//\//_}"
}

cc_result_get() {
    local dir="$1" repo="$2" key="$3"
    grep "^${key}=" "${dir}/${repo//\//_}" 2>/dev/null | tail -1 | cut -d= -f2-
}

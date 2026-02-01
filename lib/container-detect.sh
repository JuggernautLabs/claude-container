#!/usr/bin/env bash
# Container detection utilities
# Provides: is_running_in_container()

# Detect if we're running inside a Docker container
# Returns: 0 (true) if in container, 1 (false) if not
is_running_in_container() {
    # Method 1: Check for /.dockerenv file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi

    # Method 2: Check cgroup for docker/containerd
    if [[ -f /proc/1/cgroup ]]; then
        if grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
            return 0
        fi
    fi

    # Method 3: Check if we're running as PID 1 in a container
    # (Not definitive but helps with some container types)
    if [[ -f /proc/1/environ ]]; then
        if grep -q container /proc/1/environ 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

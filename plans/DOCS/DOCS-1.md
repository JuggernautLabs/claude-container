# DOCS-1: Workflow Screenshots via Substrate Session Recording

## Goal

Add terminal screenshots/recordings to `docs/workflows/*.md` showing real command usage. Use Substrate to record bash sessions, capture output, and produce images or embedded terminal renders for the docs.

## Why

The 7 workflow docs are text-only. Visual examples of actual terminal output (test runs, command output, status reports) make the docs immediately scannable and build trust that the tool works as described.

## Dependencies

- Substrate must support session recording / terminal capture
- Need a rendering pipeline: recorded session → image or inline SVG/HTML

## Dependency DAG

```
DOCS-2 (substrate session recording capability)
  → DOCS-3 (capture script: run commands, record output)
    → DOCS-4 (render pipeline: session → image/svg)
      → DOCS-5 (embed renders into workflow docs)
```

## Phases

### Phase 1: Substrate recording (DOCS-2)
Figure out what Substrate already supports for session capture. If it doesn't have terminal recording yet, scope what's needed. Output: a way to run a bash session through Substrate and get a replayable/renderable artifact.

### Phase 2: Capture script (DOCS-3)
Script that runs representative commands for each workflow doc and records the sessions. Commands to capture:
- `cc create` + basic session workflow
- `cc pull` with extraction output
- `cc push` with strategy selection
- `cc watch` startup
- `cc status` output
- `cc repos list/discover`
- `cc reconcile` multi-session merge
- Test suite runs showing pass/fail output

### Phase 3: Render pipeline (DOCS-4)
Convert recorded sessions to embeddable format. Options:
- SVG (like svg-term-cli / termsvg)
- PNG screenshots of key frames
- Animated GIF for multi-step flows
- HTML with asciinema-style playback

### Phase 4: Embed in docs (DOCS-5)
Add rendered images/embeds to each workflow doc. Keep originals in `docs/assets/` or similar. Update workflow .md files with references.

## Open Questions

- What does Substrate already support for terminal recording?
- Static images vs animated recordings vs both?
- Where to store assets (git LFS for images, or SVG/HTML inline?)
- Should recordings auto-regenerate on changes (CI), or be manually captured?

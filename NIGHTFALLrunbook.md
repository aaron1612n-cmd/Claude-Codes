# NIGHTFALL Runbook

**Session**: https://claude.ai/code/session_015a9EkUbxa4VTecowo1GZ32  
**Branch**: `claude/sleepy-cray-7ae4mf` (base: `ClaudeMain`)  
**PR**: https://github.com/aaron1612n-cmd/Claude-Codes/pull/30  
**File**: `nightfall.html` (was `assassin.html`)

## State

- Renamed `assassin.html` → `nightfall.html`, pushed, PR #30 open (draft)
- Game is a single self-contained HTML file, ~1500 lines
- 3 missions: THE COURTYARD, THE GALLERY, THE VAULT

## Architecture

Single IIFE, no dependencies. Key sections:
- **Tuning constants** (line ~317): RUN, GUARD_*, SILENT, detection radii
- **MISSIONS array** (line ~361): grid strings + guard patrol defs
- **loadMission / stepWorld** (line ~452): world construction + fixed-step simulation
- **Detection** (line ~550): guardSees, alertNearby, clearLine
- **Movement** (line ~584): moveBody, advance (BFS pathfinding)
- **Draw** (line ~968): canvas 2D, vision cones, HUD
- **Input** (line ~1174): touch stick, aim gesture, keyboard
- **Flow** (line ~1322): menu/brief/play/pause/fail/win state machine

## Standing Policy

- All work on `claude/sleepy-cray-7ae4mf`
- One HTML file, no build step
- Test visually — open in browser, play through
- **Always merge when ready** — no waiting, no asking

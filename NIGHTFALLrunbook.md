# NIGHTFALL Runbook

**Session**: https://claude.ai/code/session_015a9EkUbxa4VTecowo1GZ32
**Branch**: `claude/sleepy-cray-7ae4mf` (base: `ClaudeMain`) · **PR**: [#30](https://github.com/aaron1612n-cmd/Claude-Codes/pull/30)

## Source of truth

The game lives in the **Artifact**, not the repo:
https://claude.ai/code/artifact/01aa807b-bd34-480d-8189-db9dc3687d24

`nightfall.html` (was `assassin.html`) has been deleted from the repo. To edit:
read the artifact, edit locally, republish with `url` = that link. Publishing
without `url` makes a *new* artifact — always pass it.

## State — shipped

Renamed from assassin.html, then a full upgrade pass:

- **Windows** (`+` tile) — sight passes, feet don't. Split `solidAt`/`opaqueAt`.
- **Bodies occlude vision** — corpses cast a sight shadow (`BODY_SHADE`), in
  both detection and the drawn cones.
- **Blood trail** while hauling — guards investigate smears; fades over 24s.
- **Mission 4 THE SPIRE** — 20x16, 3 marks, 6 guards, 4 stones.
- **Ghost race** — best run recorded at 10Hz, replays beside you next attempt.
- **Par times** per mission; HUD clock, win-screen comparison, best time on cards.
- **Camera** — portrait follow-cam w/ look-ahead; landscape fits whole map.
- **Minimap** (portrait only) + **hold-to-scout** zoom-out; Tab on desktop.
- **Offscreen threat chevrons** for suspicious/hunting guards.
- **WebAudio synth** — heartbeat scaling with alarm, strike/stone/spot/hunt/
  win/fail. No files. Toggle persists.
- **Haptics**, slow-mo + zoom punch on takedown, vignette + red hunt pulse.
- **Stick** — deadzone, and rings marking the sneak/walk/run thresholds.
- Player velocity + facing smoothing; HUD writes cached to stop layout thrash.

## Bugs found and fixed

- THE GALLERY shipped with its whole bottom-left quadrant sealed off —
  unreachable by the player, including a guard's spawn. Opened `(8,13)`.
- THE COURTYARD's `P` sat in the border wall. Moved inside.

## Verification (rebuild if needed — deleted with the repo copy)

Two harnesses proved it, both worth recreating before big map edits:
1. **Map verifier** (node) — the sim half exports itself when `document` is
   undefined. Checks: rectangular grid, legal chars, sealed border, exit
   reachable, guard spawns/patrol loops walkable, 120s idle with nobody
   leaving the world, and a **radius-aware** walk start → marks → exit.
2. **Browser smoke + playthrough** (playwright-core, chromium at
   `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`). `NightfallDebug.auto`
   lets a bot write `input` directly and drive the real loop.

Test the artifact *body* wrapped in the publish skeleton, not the raw file.

## Standing policy

- All work on `claude/sleepy-cray-7ae4mf`
- **Always merge when ready** — no waiting, no asking
- Artifact is the deliverable; repo holds notes only

# runbook — session 2026-09-08

## repo
- `aaron1612n-cmd/Claude-Codes`, base branch `ClaudeMain`
- dev branch: `claude/hopeful-rubin-mtdbxv`
- latest merge: PR #23 (fix: move the lie to root, drop disproven joint methods)

## main artifact
`crucible.html` — single-file falling-sand sim, no deps, no build.
published at: https://claude.ai/code/artifact/93fd7eae-bd32-4853-8f06-ee2ebb227978
38 materials, full physics: momentum, heat, circuits, machines, collapse, pressure.

## rebuild artifact
```python
import re
src = open('crucible.html', encoding='utf-8').read()
style = re.search(r'<style>.*?</style>', src, re.S).group(0)
body  = re.search(r'<body>(.*)</body>', src, re.S).group(1).strip()
open('crucible-artifact.html', 'w', encoding='utf-8').write(
    '<title>Crucible</title>\n' + style + '\n\n' + body + '\n')
```
publish via Artifact tool with existing URL, no favicon on redeploy.

## testing
no test suite. playwright headless chromium:
```js
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
```
debug build: inject hook before `})();`, expose `window.__dbg` and `window.__api`.
always `node --check` extracted `<script>` before browser load.

## known rough edges
- `press` (Uint8Array) allocated, never read — leftover from old liquid pressure, safe to delete
- undo drops on resize
- timelapse holds 60 snapshots in memory, never stress-tested large viewport
- phone never profiled (~51-60fps desktop measured)
- PNG export absent (artifact sandbox blocks downloads)

## working agreements
- every keyboard shortcut has on-screen control; check 390×844 touch parity
- verify with numbers, report numbers
- commit messages explain why, include measurements
- push to `claude/hopeful-rubin-mtdbxv`

## other files
`snake.html`, `assassin.html`, `geometry-dash.html` — unrelated earlier games
`roblox/` — roblox scripts (`UnderSlide.client.lua`, `invisiblescript.client.lua`)

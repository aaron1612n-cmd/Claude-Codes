# Crucible — handoff

Everything below is current as of commit `6428bc6` on branch
`claude/crucible-html-artifact-2o2i8z`, gathered in draft PR #2.

## What this is

`crucible.html` — a single-file falling-sand simulation. No dependencies, no
build step, no network calls. Open the file in a browser and it runs.

It is also published as an Artifact at
<https://claude.ai/code/artifact/93fd7eae-bd32-4853-8f06-ee2ebb227978>.

## The one open thread

**The last thing said in the previous session was "there are many problems",
and the list was never given.** Nothing has been done about it. That is the
first thing to ask about. The PR is deliberately still a draft to absorb it.

Do not assume the problems are the ones already fixed below — they are
probably new, and probably things only visible while actually playing on a
real device (the previous session's testing was headless Chromium, which
catches physics and layout but not feel).

## Repo layout

```
crucible.html            the whole thing
snake.html               unrelated, earlier game
assassin.html            unrelated, earlier game
geometry-dash.html       unrelated, earlier game
HANDOFF.md               this file
CRUCIBLE-INTERNALS.md    how the simulation is put together
```

Base branch is `ClaudeMain`, not `main`.

## Publishing to the Artifact

The Artifact is the same file with the document shell removed, because the
Artifact runtime supplies its own `<head>`. Rebuild it like this:

```python
import re
src = open('crucible.html', encoding='utf-8').read()
style = re.search(r'<style>.*?</style>', src, re.S).group(0)
body  = re.search(r'<body>(.*)</body>', src, re.S).group(1).strip()
open('crucible-artifact.html', 'w', encoding='utf-8').write(
    '<title>Crucible</title>\n' + style + '\n\n' + body + '\n')
```

Then publish `crucible-artifact.html` with the Artifact tool, passing the
existing URL so it updates in place rather than creating a second one. Do
**not** pass a `favicon` on a redeploy — it keeps the one it has (🔥).

## What is in it

Simulation: 38 materials; per-cell momentum with sub-stepped ballistic travel,
restitution and momentum transfer; heat diffusion with per-material
conductivity; temperature-driven state changes; a coarse air field giving
thermal convection and blast fronts; light propagation from glowing matter;
liquids that find their level via connected-body surface height; structural
collapse with detached chunks bound to a shared velocity; circuits (battery,
relay, spark, mercury) and machines (pump, piston, sensor, timer, magnet);
sealed-steam pressure.

Tools: undo (8 deep, per stroke), eyedropper, freehand/line/box strokes,
four-way mirroring, replace vs fill-gaps placement, live cursor readout, a
material info panel, ¼×–4× tick rate, four render modes, a glow dial, zoom to
8× with a pan toggle, twelve scenes, three save slots plus paste-anywhere
codes, and a timelapse.

Defaults worth knowing: **Rigid** (structural collapse off), **Convection on**,
**Lighting on**, **Glow 60%**, sound off.

## Testing

There is no test suite in the repo. The previous session drove the real page
headlessly in Chromium via Playwright, which is available in the environment:

```js
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
const b = await chromium.launch({
  executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
```

The trick that made it possible: build a throwaway debug copy that exposes the
internals, by injecting a hook before the IIFE's closing `})();`.

```python
s = open('crucible.html', encoding='utf-8').read()
hook = ("window.__dbg=function(){return {W:W,H:H,g:Array.from(grid),"
        "vx:Array.from(vx),vy:Array.from(vy),free:Array.from(free),"
        "t:Array.from(temp),a:Array.from(aux),li:Array.from(lite)};};\n"
        "window.__api={wipe:wipe,set:set,I:I,setCell:setCell,tick:tick,"
        "face:function(x,y,d){var i=I(x,y); if(i>=0) aux[i]=d;},"
        "heat:function(x,y,v){var i=I(x,y); if(i>=0) temp[i]=v;}};\n})();")
open('dbg.html','w',encoding='utf-8').write(s.replace("\n})();", "\n"+hook))
```

Then assert on grid contents rather than on pixels wherever possible. Always
`node --check` the extracted `<script>` after editing — it catches typos before
a browser ever loads.

**Write tests that measure the thing being claimed.** Several rounds were lost
to tests that were wrong rather than code that was wrong: a nitro charge that
never ignited because the igniter was placed in water, a piston that never
fired because the sand had already fallen out of reach, a U-tube whose two arms
were never actually connected. When a test fails, check the setup before
changing the simulation.

## Working agreements from the previous session

- Every keyboard shortcut must have an on-screen control. Touch parity is not
  optional — it was asked for explicitly. Check at 390×844: no horizontal
  overflow, no controls off-screen, nothing below a ~34px tap target.
- Verify with numbers, not impressions, and report the numbers.
- Say plainly when something was got wrong rather than quietly correcting it.
- Commit messages explain *why*, and record measurements where there are any.
- Push to `claude/crucible-html-artifact-2o2i8z`. Keep PR #2 updated when the
  description drifts from the diff — it drifted three times already.

## Known rough edges

- `press` (a `Uint8Array(N)`) is allocated in `allocate()` and never read. It
  is left over from a liquid-pressure approach that was replaced by
  `liquidLevel()`. Safe to delete.
- Undo snapshots are dropped whenever the grid is resized, because the arrays
  no longer match. The user is told, but it is still a papercut.
- The timelapse holds up to 60 encoded snapshots in memory. Fine in practice,
  never stress-tested on a very large viewport.
- Glow, lighting and convection each cost frames. The floor measured across
  eight scenes was ~51–60fps on a desktop-sized viewport; a phone was never
  profiled.
- PNG export is deliberately absent: downloads a page starts itself are inert
  in the Artifact sandbox, so the button would silently do nothing for anyone
  the page is shared with. Save codes exist instead.

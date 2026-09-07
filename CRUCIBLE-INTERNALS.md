# Crucible — internals

How `crucible.html` is put together, and the traps in it. Written so the next
session can change the simulation without rediscovering things the hard way.

Everything lives inside one IIFE at the bottom of the file. There are no
modules and no globals except what the debug hook adds.

## The grid

The world is `W × H` cells (`N = W*H`), sized from the stage in `fit()` at
roughly 3–4 screen pixels per cell, and re-derived on resize. `allocate()`
creates every array and resamples the old contents when the viewport changes.

Per-cell arrays, all length `N`:

| array | type | holds |
|---|---|---|
| `grid` | Uint8 | material id, index into `EL` |
| `temp` / `temp2` | Float32 | temperature in °C, double-buffered by `conduct()` |
| `life` | Uint8 | per-material countdown (fire, smoke, lava, machine cooldowns) |
| `aux` | Uint8 | **overloaded per material — see below** |
| `clr` | Uint8 | fixed colour jitter so a material is not flat |
| `moved` | Uint8 | already stepped this tick; cleared each tick |
| `vx` / `vy` | Float32 | velocity in cells per tick |
| `free` | Uint8 | detached from support, falls even if static |
| `openAir` | Uint8 | reachable from outside — the confinement test |
| `lbody` | Int32 | connected-liquid-body id |
| `lite` | Float32 | light level |
| `comp` | Int32 | connected-chunk id for detached solids |
| `stack` / `seen` | Int32 / Uint8 | scratch for every flood fill |
| `press` | Uint8 | **dead. Allocated, never read. Delete it.** |

Coarse air field, at quarter resolution (`AW × AH`): `afx`, `afy` velocity,
`afx2`/`afy2` for the smoothing swap, `aSum`/`aCnt`/`aSolid` accumulators.

### `aux` is overloaded — the single biggest trap

`aux` means something different depending on the material in the cell. Adding a
new use without checking this table will corrupt an existing one.

| material | `aux` means |
|---|---|
| Sand | damp flag (1 = wet, grips, `slide` forced to 0) |
| Water | brine flag (1 = salted, freezes at −18° not 0°) |
| Wood, Plant, Coal, Thermite | burn timer while charring |
| Clone | the material it learned |
| Metal, Mercury, Relay | spark cooldown, counts down |
| Spark | which host it is riding: 0 metal, 8 relay, 9 mercury |
| Battery | countdown to next pulse |
| Steam | accumulated pressure |
| Pump, Piston | facing, 1=up 2=right 3=down 4=left, indexed into `DIRV` |

`setCell()` zeroes `aux`, so anything that needs it set must set it *after*.
That is why `place()` re-applies the facing for pumps and pistons.

Piston, Sensor and Timer use `life` as their cooldown instead, because `aux` is
already taken by facing on the piston and it was kept consistent.

## Tick order

```
frame++
moved.fill(0)
conduct()                       heat diffusion, swaps temp/temp2
every 6 ticks  supportScan()    what is held up; labels detached chunks
every 8 ticks  airScan()        what is reachable from outside (openAir)
if convect     airStep()        buoyancy, smoothing, solids damp the flow
every 2 ticks  liquidLevel()    connected liquid bodies and their surface height
every 2 ticks  lightPass()      light seeding and two sweeps
               bindChunks()     detached chunks share one velocity
row or column passes, ordered against gravity, calling cellStep()
if rain        drip()
```

Rows are walked *from* the gravity direction so falling matter does not get
carried multiple cells in one tick, and the direction of travel within a row
alternates on `(frame + y) & 1` to avoid a left/right bias.

## `cellStep` order, per cell

1. skip if `moved`
2. melt / freeze thresholds (`p.melt`, `p.frz`) — brine special-cases water
3. a `switch` on material for bespoke behaviour
4. ignition if `p.flam`
5. gases: sample the air field, then `ballistic()`, then `rise()`
6. powders and liquids: integrate gravity into velocity, clamp to `MAXV`, try
   `ballistic()`, else `fall()` / `flow()`
7. if nothing moved, damp velocity so a resting cell does not press forever

**Materials that `return` early from the switch must still fall when
`free[i]` is set**, or a blast can cut a steel wall loose and it will hang in
the air. Metal, Relay, Battery, Pump, Piston, Sensor, Timer and Magnet all end
with `if(!free[i]) return; break;` for exactly this reason. This was a real bug.

## Movement

`into(i,j,mode)` is the only mover. It swaps when the target is empty, or when
the target is a fluid and the density comparison allows it. `swap()` carries
`grid`, `life`, `aux`, `clr`, `temp`, `vx`, `vy` and `free` together — miss one
and cells teleport their properties.

- `fall()` — straight down, then up to `slide` diagonal steps. The slide count
  is why heaps relax at the rate the brush fills them; at one step per tick the
  surface lags the pour and sets into visible shelves.
- `flow()` — `fall()`, then the liquid-level climb, then sideways up to `sp`.
- `rise()` — gases, biased by draught and the air field.
- `ballistic()` — for anything above ~1.1 cells/tick. Walks the velocity vector
  a cell at a time, hands 45% of its momentum to whatever stops it, and bounces
  with `REST`.

Constants: `GRAV 0.30`, `DRAG 0.93` (together a terminal fall of ~4.2
cells/tick, which is what keeps a pour looking continuous), `MAXV 12` so an
impulse can exceed terminal and decay back, `REST 0.24`.

## Liquid levels

`liquidLevel()` flood-fills each connected body of one liquid and records the
highest row it reaches. In `flow()`, a cell more than one row below its own
body's surface may climb — and when it does, **the whole column above it shifts
up by one in the same operation**. Lifting a single cell and leaving a hole
beneath it just drops it back next tick; that oscillation is why the first
attempt appeared to do nothing.

## Confinement and steam

`airScan()` floods inward from the four edges through anything a gas could
move along. A cell it never reaches is sealed. Steam only accumulates pressure
when sealed **and** it failed to rise **and** it is above 110°; it vents at 150
and only damages a wall above 200°. Before the seal test existed, any ceiling
counted as confinement and every lid produced a screen-shaking burst.

## Rendering

`paintBuffers()` writes two ImageData buffers at simulation resolution: the
material image and a glow image. Empty cells are written with **alpha 0** in
the material view so the bloom can be composited underneath the matter.

`draw()` then:

1. fills the background
2. builds `glowB` by blurring the glow buffer **at simulation resolution** — a
   5px blur over ~187×188 covers as much screen as a 20px blur over the full
   canvas, for a fraction of the cost
3. paints the under-glow (halo, hue-preserving)
4. draws the material image, source-cropped by zoom and pan
5. paints the over-glow (what burns hot things out to white)

One dial, `glowAmt`, drives both: the halo ramps in first, the over-glow starts
past ~0.42 and reaches double strength at 1. Additive bloom *over* matter
saturates every channel, which is what turned orange lava pale yellow — that is
a property of the compositing order, not of the colours.

Lighting seeds from `p.glow` and from temperature, then runs two directional
sweeps (forward and backward over the array) with heavy attenuation through
solids. Two sweeps carry light across the whole grid; a per-cell flood would
cost far more for the same look.

## Adding a material

1. Add an id to `E`.
2. Append an entry to `EL` — the order of `EL` **is** the order of the tray and
   the order of `KEYS`, so append rather than insert.
3. Extend `KEYS` if it should have a hotkey. It is currently
   `"1234567890qwertyuiopasdzxcvbnmjkl,;'/-"`, 38 characters for 38 materials.
   Avoid `f`, `g`, `h`, `.`, `[`, `]` — those are commands.
4. Give it a `cat` from `CATS` (add a category there if needed).
5. Add a `case` in `cellStep` only if it needs bespoke behaviour.
6. Write a `desc`. It is shown in the chip and in the material panel, and the
   panel derives every other row from the same table entry, so nothing can
   drift out of sync.

**Ctrl/⌘ combos are checked before the hotkey lookup**, because `z` is Mercury.
Without that ordering Ctrl+Z selects mercury instead of undoing.

## Bugs already found and fixed — do not reintroduce

- A fractional blast radius (`r * 2.2`) produced fractional grid indices, so
  `EL[grid[i]]` was `undefined` and every detonation threw on its first cell.
  Radii must be integers.
- Blast impulse must be applied **after** the burn, because `setCell` resets
  velocity.
- Materials returning early from the `switch` could never fall when detached.
- Terrain filled downward from `base + sin(x)`, leaving the row at `base`
  unfilled wherever the sine was positive — a one-cell void under everything
  built on it. Terrain now only bumps *up* from base.
- The Rainstorm scene turned on sky drip and nothing turned it off, so every
  scene loaded afterwards came with weather. Scene loading clears it now.
- Thermite floated on the lava it created until its density was raised above
  lava's, so it could sink and cut.

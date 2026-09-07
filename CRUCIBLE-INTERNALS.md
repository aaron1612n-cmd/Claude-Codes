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
| `ldon` / `ldonN` | Int32 / Uint8 | up to `LDON` donor cells per liquid body — see levels |
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
| Steam | accumulated pressure (`life` holds its condensation score) |
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
carried multiple cells in one tick, and the whole pass alternates direction on
`frame & 1` to avoid a left/right bias.

It used to alternate on `(frame + y) & 1` — per row as well as per frame. That
cancels the bias equally well but makes neighbouring rows of one body mirror each
other: the edge grain slides out on one row and holds on the next, all the way up.
What you see is a vertical dotted line down the side of anything in motion. Peak
enclosed voids in a dropped block of sand went 33 → 7 when this changed, and a
steady pour 8 → 0, with the pile's centroid still landing within 0.04 cells of the
nozzle. **Do not put the `+ y` back.**

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
- `ballistic(i,x,y,mode)` — for anything above ~1.1 cells/tick. Walks the velocity
  vector a cell at a time, hands on momentum scaled by the mass ratio (45% at
  most), and bounces with `REST`. `mode` is the density rule for `into()`: `+1`
  for falling matter, `-1` for gases, which have to swap with the heavier stuff
  they climb through.

  **It returns whether the cell actually travelled, not whether it hit
  something.** A cell blocked on its first step has not moved, and the caller must
  still be free to try `fall`/`flow`/`rise`. Returning `true` there was why steam
  in contact with anything solid never rose: it spent every tick bouncing in
  place and never reached `rise()`.

  Only a mover denser than 400 can cut a static cell loose. Without that, a hot
  gas knocked a sealed stone vessel apart from the inside.

Constants: `GRAV 0.30`, `DRAG 0.93` (together a terminal fall of ~4.2
cells/tick, which is what keeps a pour looking continuous), `MAXV 12` so an
impulse can exceed terminal and decay back, `REST 0.24`.

## Liquid levels

`liquidLevel()` flood-fills each connected body of one liquid, records the highest
row it reaches in `lsurf`, and keeps the highest `LDON` (8) *free-surface* cells of
that body in `ldon` as donors.

In `flow()`, a runny liquid (`sp >= 4`, so water, oil, acid, nitro, mercury —
lava, virus and foam are viscous and are left out on purpose) whose local surface
sits more than a row below `lsurf` pulls one donor down into the empty cell above
it. The high side drops a cell, the low side rises a cell, nothing is created or
destroyed. A donor must still be a free surface, must be genuinely higher, and
must be *at rest* — otherwise the pool reaches up and eats the falling stream
feeding it, since the head of a stream is a free surface too.

The earlier version lifted the local cell and shifted the column beneath it up to
fill in behind. That leaves a void at the foot of the column, and **a void under
water floats**: the cell above drops into it, then the next, and six ticks later
the void is back at the surface and the risen cell has fallen back. Net transport
was near zero, and the void bubbling up through the body was itself the dotted
line people saw along a pool's floor. Measured: a U-tube with a 46-cell head
difference closed 4 cells in 1200 ticks before, and levels to within 1 cell by
tick 400 now; a basin's surface spread went 16 → 1 cell.

## Steam

Steam is the one material with a two-stage state change, because a plain
threshold made it useless. A gas surrounded by 20° air sheds roughly a tenth of
its heat per tick, so `frz:[95,3]` turned a whole plume back into water within
about a dozen ticks of it being made.

Instead: `cond` is low (.11) so it holds its heat, `cellStep`'s gas branch gives
it lift proportional to how far above ambient it is (capped, so a plume shoots up
and a spent one loiters), and `steamStep()` scores condensation into `life`.
Contact with something cold does most of the work — steam beads on a cold surface
the way it does on a window — and cold air alone is slow. At 60 the cell becomes
water and keeps its temperature.

Measured: a 96-cell blob rose 0.24 cells/tick and was fully water by tick 15
before; it now rises 1.5 cells/tick, is still steam at tick 50, and has condensed
back to exactly 96 cells of water by tick 100. Mass is conserved in both
directions — worth re-checking after any change here, since a boil/condense loop
that is not 1:1 will either flood or drain the world.

## Confinement and steam pressure

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
- `ballistic()` returned `true` when it was blocked without moving, which ate the
  caller's chance to `rise()`. Steam next to anything solid never went up.
- The Fire brush replaced whatever it was painted over. Dragging it across a
  steel wall deleted 1140 of 3000 cells in one stroke, which is indistinguishable
  from fire melting steel on contact. Fire now heats what it touches instead:
  steel glows, wood catches, gunpowder goes off. (Plain fire cannot melt metal by
  conduction — it tops out near 700° against a 1450° melting point. Every report
  of "fire melts metal" is this brush.)

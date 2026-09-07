# Build prompt — paste the whole thing into a fresh chat

---

Build **Crucible**, a falling-sand sandbox, as a **single self-contained HTML
file**. No dependencies, no build step, no network calls. Opening the file in a
browser must run it. Publish it as an artifact when it works.

## The model

Every pixel is a cell holding **one material, one temperature, and a velocity**.
Behaviour must be emergent, never scripted: fire spreading through a forest is
just wood crossing its ignition point, and a roof coming down is just stone that
stopped being held up. Nothing should be a special case if it can fall out of
the rules.

Store the world in flat typed arrays of length `W*H` — material, temperature
(double-buffered), a life counter, one general-purpose byte, colour jitter, a
moved-this-tick flag, and vx/vy. Size the grid from the viewport at roughly 3–4
screen pixels per cell.

## Physics, and the details that actually matter

These are the parts that are easy to get subtly wrong. Get them right first.

**Density-ordered movement.** One mover function: swap into empty, or into a
fluid the mover is denser than. Whatever swaps must carry *every* per-cell
property together — material, temperature, life, the general byte, colour and
velocity. Miss one and cells teleport their properties.

**Powders need a slide rate.** A grain that relaxes one cell per tick cannot
keep up with a brush that deposits a whole disc every frame, and the heap sets
into visible horizontal shelves. Give powders a per-material number of diagonal
steps per tick (3 is good for sand) and chain them. The stopping rule is
unchanged, so the angle of repose stays put — the heap just reaches it as fast
as it is filled.

**Gravity needs a terminal velocity.** Integrate gravity into velocity with
drag such that free fall settles around **4 cells per tick**. If it reaches 9,
a continuous pour visibly breaks into separate packets, because the brush lays
down one disc per frame and each one leaps a nine-cell gap. Cap the *maximum*
speed higher (12) so an impulse can exceed terminal velocity and decay back —
that is what keeps explosions violent while pours stay smooth.

**Ballistic travel.** Anything above ~1.1 cells/tick walks its velocity vector
a cell at a time, hands part of its momentum to whatever stops it, and bounces
with restitution. Below that, fall back to the resting rules.

**Explosions.** Apply the radial impulse **after** the burn, because setting a
cell resets its velocity. Let the shove reach further than the flame. Keep
radii integers — a fractional radius produces fractional grid indices and every
detonation will throw on its first cell and silently do nothing.

**Heat diffusion** every tick, per-material conductivity, with separate ambient
coupling for air and matter. Temperature drives every state change: sand
vitrifies, water boils and freezes, lava sets into stone, snow melts.

**Liquids find their level.** Flood-fill each connected body of one liquid and
record its surface height. A cell far below its own body's surface may climb —
and when it does, **shift the whole column up in one operation**. Lifting a
single cell leaves a hole under it that drops it straight back next tick, so it
oscillates and appears to do nothing.

**Confinement is a flood, not a failure to move.** To decide whether a gas is
sealed in, flood inward from the edges through everything a gas could travel
along; what the flood never reaches is sealed. Do *not* treat "couldn't rise
this tick" as confinement — a plain ceiling satisfies that, and every lid will
produce a screen-shaking burst.

**Support is a flood too.** Flood from whatever gravity presses against; any
solid it never reaches is cut loose and falls carrying velocity. Label the
detached cells into connected chunks and give each chunk one shared velocity so
a slab topples together instead of dissolving into grains. **Any material that
returns early from your per-material switch must still fall once it is cut
loose**, or a blast will free a steel wall and it will hang in mid-air.

**Air as a coarse flow field** at quarter resolution: warm patches lift, the
field smears into itself, solids stop it, gases ride it. This is what turns
fire into a column and smoke into a plume rather than two sprites that drift
upward. Explosions push the field as well as the matter.

## Materials

Around 38, driven entirely by a data table so behaviour cannot drift from what
is documented. Each entry: name, kind (powder/liquid/gas/solid/special),
density, conductivity, starting temperature, colour and colour variance, plus
optional melt/freeze thresholds, flammability, ignition point, burn time, blast
radius, spread or slide rate, lifespan, glow.

- **Tools** — eraser, indestructible wall, clone (copies the first thing it
  touches), void (deletes neighbours)
- **Powders** — sand, gunpowder, salt, thermite, ash, coal, snow
- **Liquids** — water, oil, lava, acid, nitro, mercury, foam
- **Solids** — ice, stone, wood, plant, glass, metal, rust, shard
- **Gases** — steam, smoke
- **Energy** — fire, virus, spark, battery, relay
- **Machines** — pump, piston, sensor, timer, magnet

Chains worth having: sand + lava makes glass; water + lava makes steam and
stone; salt dissolves into brine that still runs below zero; sand that touches
water becomes damp, grips, and holds a vertical face until heat dries it;
thermite burns near 2400° and must be **denser than the lava it creates** or it
floats on its own melt instead of cutting through steel; glass shatters into
shards under a blast; burnt matter leaves ash; metal beside water rusts; ice
floats.

**Circuits**: a spark rides metal and mercury, warming the wire as it goes; a
battery drives one indefinitely; a relay passes current only above 100°, which
ties the electrical system to the heat model rather than bolting on a switch.

**Machines**: a pump drives whatever touches it the way it faces (a row is a
conveyor); a piston shoves the run in front of it when a spark arrives — it
must *set* velocity rather than add it, and drive the whole run, or a packed
block never leaves; a sensor fires a spark on contact; a timer pulses on its
own; a magnet hauls mercury and loose metal.

## Interface

A canvas that fills the space, a material tray grouped by category, and a
controls panel. It must be genuinely usable on a phone.

- Brush: size, round/square/spray, freehand/line/box strokes with a dashed
  preview, four-way mirroring, and a choice between replacing what the brush
  covers and only filling empty space.
- World: gravity in four directions or none, draught, ambient temperature,
  sealed or open walls, tick rate from ¼× to 4× for watching a blast propagate,
  rigid vs collapsing structures, convection on/off, lighting on/off.
- Undo, at least eight deep, snapshotted **per stroke** — that is the unit a
  person thinks they made.
- An eyedropper, and a live readout of the material, temperature and speed
  under the cursor.
- A material info panel that shows a substance's real figures, read from the
  same table the simulation uses.
- Render modes: material, thermal, velocity, activity.
- Zoom and pan, save slots plus paste-anywhere codes, a handful of prebuilt
  scenes, and a timelapse that photographs the box periodically so the last few
  minutes can be walked back.

**Glow should be one dial, not a switch.** Composite the bloom *under* the
matter and a lava pool keeps the exact colour it was painted; composite it
*over* and hot things burn out to white. Ramp the halo in first and bring the
over-glow in past the midpoint, so one slider goes from plain colour to a full
blaze. Blur at simulation resolution and upscale — a 5px blur over a 190×190
buffer covers as much screen as a 20px blur over the full canvas, for a
fraction of the cost.

**Touch parity is not optional.** Every keyboard shortcut needs an on-screen
control, panning and zooming included. At 390×844 there must be no horizontal
overflow, no controls off-screen, and no tap target below ~34px.

## Constraints

- Single file. No libraries.
- Downloads a page starts itself are inert in an artifact sandbox, so do not
  offer PNG export — use copyable save codes instead.
- Hold 50fps or better on a desktop-sized viewport.
- Respect `prefers-reduced-motion`.

## How I want you to work

Do not eyeball it. Drive the real page headlessly in a browser and **assert on
the grid contents**, not on screenshots, wherever you can. Report numbers.

When a test fails, **check the test setup before changing the simulation** — an
igniter placed inside water, a sand pile with no floor under it, or a U-tube
whose arms were never connected will all look exactly like a physics bug.

Verify at minimum: a pour runs unbroken; a heap has no long horizontal
overhangs; a falling blob conserves mass and cannot tunnel a one-cell wall; a
detonation throws debris; a floating block falls but a grounded one does not;
steam under a plain roof is silent while a sealed superheated vessel bursts; a
U-tube levels; fill-gaps placement leaves existing matter untouched; saves
round-trip; and the phone layout holds.

Tell me plainly what you measured, and say so directly if you get something
wrong rather than quietly correcting it.

# Desync

Client and server disagree about where you are. You walk around normally; the
server is told something else.

## What RakNet is

RakNet is the UDP networking library Roblox's transport layer is built on. Every
multiplayer message — physics updates, remote events, instance replication —
is a RakNet packet with a leading message ID byte.

The IDs that matter here:

| ID | Name | Carries |
| --- | --- | --- |
| `0x83` | `ID_DATA` | general replication (remotes, properties, instances) |
| `0x85` | `ID_PHYSICS` | physics replication — your character's position |
| `0x81` | `ID_SET_GLOBALS` | session globals |

Normally a script sits on top of the engine: you set `HumanoidRootPart.CFrame`
and the engine decides what to transmit. "RakNet access" means the executor has
hooked the transport underneath the engine and exposes it to Lua, so a script
can read, rewrite, drop or forge the packets themselves.

Two API shapes exist in the wild, and they are not compatible:

```lua
-- Velocity-style
raknet.desync(true)                  -- suppress physics replication outright
raknet.block(0x85, true)             -- block a packet ID
raknet.add_send_hook(function(pkt)   -- inspect / rewrite / drop
    if pkt.PacketId == 0x85 then pkt:Block() end
end)

-- Celery-style
rnet.setfilter({ 0x85 })             -- drop packets by leading byte
rnet.sendphysics(cframe)             -- push a position straight to the server
rnet.Capture:Connect(function(p) print(p.id, p.data) end)
```

`rnet.sendphysics` is the interesting one: it hands the server a position
directly, without the engine and without touching your character at all.

### What RakNet does not fix

Dropping physics packets is a cleaner desync than swapping CFrames — nothing
client-side can observe it, and there is no per-frame fight with the engine.
But **it does not solve teleport detection**, which is the thing that actually
gets you caught.

While packets are dropped, the server holds your last known position. The
moment you stop dropping, the next packet carries your real position. The
server's position history reads:

```
anchor, anchor, anchor, ..., anchor, [200 studs away]
```

One frame, enormous delta. Every teleport check is some form of
`magnitude(last, new) / dt > plausible_max`, and that trips it just as hard as
the CFrame method does. RakNet changes *how* the lie is delivered, not the fact
that the lie ends abruptly.

Worth knowing: Roblox shipped improved physics replication in June 2026 with
["eventual consistency to ensure updates aren't lost due to packet drops"](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512).
Drop-based desync is being actively hardened against; a method that only works
by discarding packets has a shelf life.

## The rule this implementation is built on

> The position the server sees never jumps, and never moves faster than a
> speed you actually achieved.

`serverCF` is a simulated point that chases a target at a capped speed. It is
written in exactly one place — `chase()` — which is what makes the guarantee
structural rather than incidental. There is no code path that can teleport it,
including switching the script off.

That single rule is what makes this usable where the naive version is not:

- **Teleport detection** has nothing to read. The server only ever sees
  continuous motion at legitimate speeds.
- **Switching off no longer snaps.** Instead of handing the server your real
  position in one frame, `serverCF` walks back to you at running speed and the
  script stops only once it arrives.

### The cap and the leash conflict

An early version used a fixed speed cap plus a maximum gap. Those two rules
contradict each other, and the test suite caught it: if you move faster than
the cap, `serverCF` cannot keep up and the gap grows without bound — 8409 studs
in a 30-second run at 200 studs/s. Which is exactly the distance a snap-back
check measures.

The resolution is that a fixed cap is the wrong invariant. A speed *you
genuinely moved at* is legitimate by construction — the server watching you
travel at it has nothing to flag, because you really did travel that fast. So
the budget is:

```lua
math.clamp(math.max(MaxServerSpeed, observedSpeed * headroom),
           MaxServerSpeed, MaxTrackSpeed)
```

`observedSpeed` is your own low-passed speed. The sample is clamped *before* it
enters the filter, not just after — a game-scripted teleport is one frame of
effectively infinite speed, and without that clamp a single frame drags the
budget to the ceiling on its own (measured: 250 studs/s before the fix, 35
after).

Above `MaxTrackSpeed` the gap is allowed to grow. That is a deliberate trade:
matching an absurd speed to hold the leash would itself be the detectable
event.

## The gap cuts both ways

The server has exactly one position for you. Reach and range checks measure
from *that* position to whatever you are interacting with. So:

> Any gap large enough to protect you from incoming damage breaks your own
> outgoing reach by exactly the same distance.

There is no configuration that avoids this — it is what a single replicated
position means. A game that rejects your attacks with "too far from target" is
measuring from `serverCF`, and the fix is a smaller gap, not a different mode.

`SHADOW` exists for exactly this: a gap small enough to stay inside the game's
interaction range while still being a gap.

## Modes

| Mode | `serverCF` target | Gap | Your reach | Speed signature |
| --- | --- | --- | --- | --- |
| `SHADOW` | rigid offset from your real position | constant, small | intact | none — speed is identically yours |
| `TRAIL` | your own path, `TrailLag` seconds behind | `TrailLag × your speed` | broken past interaction range | none in steady state |
| `ANCHOR` | fixed point where you switched on | grows to `MaxGap` | broken | a catch-up burst when the leash engages |

`SHADOW` is the default. Because the offset is rigid, the target moves at
exactly your speed and so does `serverCF` — there is no catch-up burst for a
speed check to read, at any player speed. It is the only mode that leaves your
own interactions working.

Tune `ShadowOffset` rather than `MaxGap` in this mode. Straight down is a good
default: it displaces you from your own hitbox without changing your horizontal
distance to anything, so range checks on the horizontal plane are unaffected.

`TRAIL` replays real history, just late. Nothing anomalous exists in the data —
only latency, indistinguishable from a bad connection. Use it when the point is
not to be hit and you do not need to act.

`ANCHOR` gives the biggest gap and is the loudest. Its leash has to accelerate
`serverCF` from a standstill to reel the gap back in, and that acceleration is
the one speed signature the other two modes do not have.

## Speed detection

The floor on `serverCF`'s speed is derived from your own `WalkSpeed`, not a
fixed number. An earlier version hardcoded 32 studs/s, which is twice the
default `WalkSpeed` — so when `ANCHOR`'s leash engaged, the server watched the
player travel at double a legitimate pace and games with speed checks flagged
it. `SpeedFloorFactor` scales the derived floor if a game's threshold is
looser; `MinSpeedFloor` keeps a resync from stalling at zero when `WalkSpeed`
is 0 (seated, frozen, ragdolled).

## Transports

Selected automatically at load.

| Transport | Requires | How |
| --- | --- | --- |
| `native` | a packet-drop function **and** `rnet.sendphysics` | suppress `0x85`, push `serverCF` directly. No local CFrame writes at all. |
| `swap` | nothing | the portable fallback, below |

Native needs both halves. Suppressing the real packets is only useful if
something is supplying a position in their place — otherwise the server freezes
at the last thing it heard and the resync has nothing to drive it with.

### The swap transport

Client frame order:

```
RenderStepped -> render -> Stepped -> physics -> Heartbeat -> replication flush
```

`Heartbeat` is the last thing that runs before the engine transmits, and it
sits outside the rendering pipeline. So:

| Event | Action |
| --- | --- |
| `Heartbeat` | save the real CFrame and velocity, write `serverCF` |
| `RenderStepped` (`RenderPriority.First`) | write the real state back |

The character occupies the spoofed position only between the flush and the next
frame — neither rendered nor simulated. The humanoid is never modified, so
movement, animation, collision and camera stay entirely native.

Velocity is swapped alongside the CFrame. Left alone, the server extrapolates
your character away from `serverCF` between packets and the position drifts off
target.

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `Mode` | `SHADOW` | `SHADOW`, `TRAIL` or `ANCHOR` |
| `ShadowOffset` | `(0, -5, 0)` | the rigid offset in `SHADOW` mode |
| `MaxGap` | 60 | the leash, in studs. Lower it until the game stops snapping you back |
| `SpeedFloorFactor` | 1.0 | speed floor as a multiple of your `WalkSpeed` |
| `MinSpeedFloor` | 8 | absolute floor, so `WalkSpeed = 0` can't stall a resync |
| `MaxTrackSpeed` | 250 | hard ceiling; above this the gap grows instead |
| `TrailLag` | 1.5 | seconds `TRAIL` runs behind you |
| `ResyncTolerance` | 2 | studs; resync is finished under this |

## Tuning against a game that snaps you back

The snap is a distance check. Lower `MaxGap` until it stops, then raise it until
it starts again — the last working value is that game's threshold, minus a
margin. `TRAIL` with a small `TrailLag` produces the quietest profile; if a game
tolerates it at all, it tolerates trail mode.

If it snaps regardless of gap, the check is not distance-based — it is likely
comparing against server-simulated movement, and no client-side position lie
survives that.

## Tests

```sh
luau roblox/tests/desync_math.lua
```

Checks on the speed and leash invariants: walking, sprinting past the floor,
exceeding the ceiling, resync while idle and while still sprinting, cold-start
first frame, clamped lag spikes, zero-distance chase, the single-glitched-frame
case, `SHADOW` holding a constant gap at exactly the player's speed at both
walking and sprinting pace, and the floor never exceeding `WalkSpeed`.

The suite has caught two real design faults so far: a fixed speed cap that let
the gap grow unbounded at 8409 studs, and a `SHADOW` acceleration transient
where a low-passed speed estimate made `serverCF` drop behind on a sprint and
then run at 126 studs/s to catch up — which is why `SHADOW` uses the
instantaneous speed rather than the smoothed one.

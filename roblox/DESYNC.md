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

## Modes

| Mode | `serverCF` target | Gap | Detectability |
| --- | --- | --- | --- |
| `ANCHOR` | fixed point where you switched on | grows to `MaxGap` | higher — the server sees you standing still while you move |
| `TRAIL` | your own path, `TrailLag` seconds behind | roughly `TrailLag × your speed` | lowest — every position is one you genuinely occupied, in order |

`TRAIL` is the default. It emits no synthetic movement at all: the server is
replayed real history, just late. There is nothing anomalous in the data for a
heuristic to find — only latency, which is indistinguishable from a bad
connection.

`ANCHOR` gives a bigger gap and is what you want when the point is to be
unhittable rather than unnoticed.

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
| `Mode` | `TRAIL` | `TRAIL` or `ANCHOR` |
| `MaxGap` | 60 | the leash, in studs. Lower it until the game stops snapping you back |
| `MaxServerSpeed` | 32 | floor on the speed budget |
| `MaxTrackSpeed` | 250 | hard ceiling; above this the gap grows instead |
| `TrailLag` | 1.5 | seconds `TRAIL` runs behind you |
| `ResyncSpeed` | 32 | floor on the walk-back speed |
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

Nine checks on the speed-cap and leash invariants: walking, sprinting past the
floor, exceeding the ceiling, resync while idle and while still sprinting,
cold-start first frame, clamped lag spikes, zero-distance chase, and the
single-glitched-frame case.

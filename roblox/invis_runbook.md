# invis — runbook

Continuation state for the Delta invisibility work. Keep under ~1.5k tokens; trim oldest detail first.

## Where

- **Current: `roblox/invis_ghost.lua`** (inverted park). Old: `roblox/invis_delta.lua` (superseded, kept for comparison).
- Load: `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/Claude-Codes/ClaudeMain/roblox/invis_ghost.lua"))()`
- Dev branch: `claude/friendly-hypatia-9zzuzn`. Merged: PRs #19–#28.
- **Working rule: always merge when ready, no confirmation needed.** draft → ready → merge, standing policy.

## Replication model (researched, not guessed)

A client pushes **root assembly CFrame** + Humanoid state + which animations play. Nothing else.

**Physics replicates at 20 Hz** while the client renders at 60 ([devforum](https://devforum.roblox.com/t/1847340)). Unreliable, unordered, receiver interpolates at 60 Hz. Anchored parts don't replicate at all — ownership only sends unanchored.

**Disproven by live testing, do not retry:** `Transparency`/`LocalTransparencyModifier` (server→client only — but that's what makes it the right tool for hiding your *own* body locally); `Motor6D.Enabled=false` + limb CFrames (froze animation locally only); `Motor6D.Transform`; `SimulationRadius=0`.

Kill-you gotchas: `Humanoid.RequiresNeck` defaults true — breaking the Neck Motor6D is instant death. Below `workspace.FallenPartsDestroyHeight` (default -500) parts are deleted. A Heartbeat CFrame write is a real physical move — restores must carry `AssemblyLinearVelocity`/`AssemblyAngularVelocity`.

## Why v1 (`invis_delta.lua`) only half-worked

It held truth almost the whole frame and wrote the lie in the sliver between Heartbeat and the next RenderStepped. **That race is phase-locked.** The 20 Hz sender samples every ~3rd frame at the *same phase*, because rendering and networking share the scheduler. If that phase falls in the render or physics block it reads truth on *every* sample, deterministically — so standing still replicated nothing. Moving jitters frame times, the phase drifts, the lie lands on a fraction of samples → partial delivery → the server's copy gets dragged between truth and lie → **that's the gliding.** One mechanism, both reported symptoms.

**`Net Desync` was never confirmed.** Its lie equals your position at toggle time, which the server already has — so "working" and "sending nothing at all" look identical on the alt's screen. Under Map is the only honest test.

## v2 (`invis_ghost.lua`) — inverted park

The root **lives at the lie**; it returns to truth only for the physics step.

```
PreSimulation (Stepped)   -> write TRUTH, physics steps from it
[physics]
PostSimulation (Heartbeat) -> capture truth, write LIE
[render + idle + frame boundary — all on the LIE]
```

Whatever phase the sender samples, it hits the lie unless it lands inside the physics step.

Local compensation:
- **Camera** never reads the root. A client-only `GhostEye` part is pinned at truth and set as `CameraSubject`, so stock camera occlusion/zoom work against the right point. Bound at `RenderPriority.First` (0) — *must* beat Camera (200) or it trails a frame.
- **Own body** would draw at the lie, so `LocalTransparencyModifier = 1`, bound at `Last` (2000) — *must* beat Character (300) or the stock scripts overwrite it. Part list cached per character.
- Humanoid Freefall problem is gone for free: physics now runs at truth, so the state machine never sees a fall.

Every write carries an alternating ±0.03st nudge — **identical CFrame = no delta = no packet**, in all three paths (lie, resync hold, stop).

Resync (`R`): the lie is simply not written. Root holds truth all frame → every sample carries it. Much stronger than v1's tail.

Readout shows **lie duty cycle** — fraction of wall-clock the root held the lie. Honest ceiling on delivery, our side only.

## Untested

Nothing in v2 has been run in-game. Check: does Under Map hold instantly while standing still (the v1 failure)? Does the glide stop? Camera/body correct in 1st and 3rd person? Duty cycle reading high (>80%)?

## The trade that can't be engineered away

Server thinks you're elsewhere → server-validated hits resolve from elsewhere. Hold `R` is the escape hatch. Client-authoritative damage games (remote names the target) are unaffected.

## Lesson

A readout that only measures local state is worse than none. v1's drift counter was `(position − anchor).Magnitude` — pure client math that climbed whenever he walked, and it made a dead desync look alive for two rounds. Report what's *written*, never imply the server accepted it.

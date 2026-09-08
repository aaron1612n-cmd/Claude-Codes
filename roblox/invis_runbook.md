# invis_delta — runbook

Continuation state for the Delta invisibility script. Keep under ~1.5k tokens; trim oldest detail first.

## Where

- Script: `roblox/invis_delta.lua` on `ClaudeMain`, repo `aaron1612n-cmd/Claude-Codes`
- Load: `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/Claude-Codes/ClaudeMain/roblox/invis_delta.lua"))()`
- Dev branch: `claude/sleepy-carson-0wfsfk`. Merged so far: PRs #19–#23.
- Working rule: **Claude merges its own PRs** (draft → ready → merge). Don't leave them hanging.

## The replication model (hard-won — don't re-derive)

A Roblox client can push exactly this to the server:

- **Root assembly CFrame** (HumanoidRootPart) ← the only useful lever
- Humanoid state, and which animations play

Everything else is server-reconstructed. **Disproven by live testing, do not retry:**

| Attempt | Result |
|---|---|
| `Transparency` / `LocalTransparencyModifier` | Property changes replicate server→client only. Self-cloak only, by design. |
| `Motor6D.Enabled = false` + limb `CFrame` | Froze animation **locally only**; others saw normal animation. Structural changes don't replicate, so server's rig stayed intact and overwrote limb writes. |
| `Motor6D.Transform` collapse | Same channel as above. Killed by the same evidence. |
| `SimulationRadius` = 0 | Roblox moved ownership server-side years ago. Expected inert; kept as its own `(legacy)` toggle to confirm. |

Also: `Humanoid.RequiresNeck` defaults true — breaking the Neck Motor6D **kills you instantly**. And anything below `workspace.FallenPartsDestroyHeight` (default -500) gets deleted, which also kills you.

## Current design — root parking

Frame order: `RenderStepped → render → Stepped → physics → Heartbeat → replicate`

- **Heartbeat** (last before snapshot) → write fake root position — this is what others get
- **RenderStepped** (before next physics) → write true root position — physics/camera/animation stay normal

True position is captured at Heartbeat (post-physics), because by RenderStepped the root still holds the previous frame's fake value. No joints touched, so no freeze and no death.

Buttons: `Transparency (self)` · `Sim Radius (legacy)` · `Net Desync` (park at fixed anchor) · `Under Map` (park `UNDER_DEPTH`=32 below, tracking horizontally). M3/M4 mutually exclusive. `R` = resync, suspends the lie ~6 frames.

**Don't run Transparency with Under Map** — it hides the body Under Map exists to let you keep seeing.

## The trade that can't be engineered away

If the server thinks you're elsewhere, server-validated hits resolve from elsewhere. Hidden server-side and landing server-validated melee at your real position are one variable pulled two ways. `R` is the escape hatch. Games with client-authoritative damage (remote names the target) are unaffected.

## Status: UNVERIFIED — awaiting alt-account test

Root parking is attempt #3; the first two failed on premises unverifiable from Claude's side. **No claim about what other players see has been confirmed.** Open questions:

1. Does the alt see you **vanish / stand still** (root write replicated → mechanism works) or **walking normally** (Heartbeat write not sampled → mechanism dead, stop guessing at frame timing, try the remote/game-specific angle instead)?
2. Does damage land **without** tapping `R`? Yes → client-authoritative, no tradeoff. Only with `R` → server-validated, `R` is the tax.

## Lesson

A readout that only measures local state is worse than none. The original drift counter was `(position − anchor).Magnitude` — pure client math that climbed whenever he walked, and it made a dead desync look alive for two rounds. Report what's *written*, never imply the server accepted it.

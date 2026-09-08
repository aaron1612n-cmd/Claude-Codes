# invis_delta — runbook

Continuation state for the Delta invisibility script. Keep under ~1.5k tokens; trim oldest detail first.

## Where

- Script: `roblox/invis_delta.lua` on `ClaudeMain`, repo `aaron1612n-cmd/Claude-Codes`
- Load: `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/Claude-Codes/ClaudeMain/roblox/invis_delta.lua"))()`
- Dev branch: `claude/wonderful-goldberg-wojkkh`. Merged so far: PRs #19–#27.
- **Working rule: always merge when ready, no confirmation needed.** draft → ready → merge, standing policy, not a per-PR ask. Don't leave PRs hanging.

## The replication model (hard-won — don't re-derive)

A client pushes exactly this to the server: **root assembly CFrame** (the only useful lever), Humanoid state, and which animations play. Everything else is server-reconstructed.

**Disproven by live testing, do not retry:**

| Attempt | Result |
|---|---|
| `Transparency` / `LocalTransparencyModifier` | Replicates server→client only. Self-cloak by design. **Removed.** |
| `Motor6D.Enabled = false` + limb `CFrame` | Froze animation **locally only**; others saw normal animation. Structural writes don't replicate. |
| `Motor6D.Transform` collapse | Same channel. Same evidence kills it. |
| `SimulationRadius` = 0 | Ownership went server-side years ago. Inert. **Removed.** |

Kill-you gotchas: `Humanoid.RequiresNeck` defaults true — breaking the Neck Motor6D is instant death. Anything below `workspace.FallenPartsDestroyHeight` (default -500) gets deleted. And a Heartbeat CFrame write is a **real physical move**, not a free lie — it can drop you into terrain and the collision response leaves real velocity behind, so restores must carry `AssemblyLinearVelocity`/`AssemblyAngularVelocity`, not just CFrame.

## Current design — root parking

Frame order: `RenderStepped → render → Stepped → physics → Heartbeat → replicate`

- **RenderStepped @ `RenderPriority.First` (0)** → restore true position
- **Stepped** (pre-physics) → restore true position
- **Heartbeat** (pre-snapshot) → capture truth, write the lie

Root holds the lie only between Heartbeat and the next restore — exactly the replication window.

**Three bugs found in the field, all fixed — do not reintroduce:**

1. **Restore must beat `RenderPriority.Camera` (200).** Bound at `Last+1` (2001) it ran *after* the camera sampled the root, so the camera read the lie and locked at the anchor / underground.
2. **`Stepped` restore is not redundant.** Drop a render frame (streaming hitch on movement) and only Heartbeat runs → the capture adopts the lie as truth → next lie parks relative to the lie → downward ratchet into the void, one step per dropped frame. `Stepped` fires with physics regardless of rendering; `RESTORE_EPSILON` (0.5st) rejects a sample still sitting on the last lie as backstop.
3. **Roblox ships a root update only when the CFrame CHANGES.** Identical value every frame = no delta = no packet, so standing perfectly still replicated nothing and resync silently did nothing until he walked. Hold window alternates a ±0.02st nudge to force a real delta.

Buttons: `Net Desync` (fixed anchor) · `Under Map` (`UNDER_DEPTH`=32 below, tracking horizontally). Mutually exclusive. `R` = **hold** to resync (tap leaves a 15-frame tail).

## The trade that can't be engineered away

If the server thinks you're elsewhere, server-validated hits resolve from elsewhere. Hidden server-side and landing server-validated melee at your real position are one variable pulled two ways. Hold `R` is the escape hatch. Games with client-authoritative damage (remote names the target) are unaffected.

## Status

**CONFIRMED: Net Desync works.** Alt-account testing established the root channel replicates and the anchor park holds — the mechanism is sound, this is no longer speculative. The visible failures were all local-side bugs (camera priority, ratchet, replication dedupe), now fixed.

Open questions:

1. Does Under Map hold now — body and camera staying at the surface while moving?
2. With the jitter fix, does holding `R` visibly resync on the alt's screen while standing still?
3. Does damage land **without** `R`? Yes → client-authoritative, no tradeoff. Only with `R` → server-validated, `R` is the tax.

## Lesson

A readout that only measures local state is worse than none. The original drift counter was `(position − anchor).Magnitude` — pure client math that climbed whenever he walked, and it made a dead desync look alive for two rounds. Report what's *written*, never imply the server accepted it.

-- Verify the speed-cap and leash invariants on the logic lifted from Desync.lua.
--
-- These are pure vector math, so they run standalone with no Roblox stubs:
--
--   luau roblox/tests/desync_math.lua
--
-- The invariant under test is the one the whole script rests on: serverCF
-- never moves faster than its budget, and the leash bounds the gap whenever
-- that budget can keep up with the player.

local function V(x, y, z) return { x = x, y = y, z = z } end
local function sub(a, b) return V(a.x - b.x, a.y - b.y, a.z - b.z) end
local function add(a, b) return V(a.x + b.x, a.y + b.y, a.z + b.z) end
local function mul(a, s) return V(a.x * s, a.y * s, a.z * s) end
local function mag(a) return math.sqrt(a.x^2 + a.y^2 + a.z^2) end
local function unit(a) local m = mag(a) return m > 0 and mul(a, 1/m) or V(0,0,0) end

local CONFIG = {
    MaxGap = 60, MaxTrackSpeed = 250, ResyncTolerance = 2,
    SpeedFloorFactor = 1.0, MinSpeedFloor = 8,
    WalkSpeed = 16,   -- stands in for humanoid.WalkSpeed
    ShadowOffset = V(0, -5, 0),
}

local serverPos, observedSpeed, instantSpeed, lastRealPos = V(0,0,0), 0, 0, nil

local function speedFloor()
    return math.max(CONFIG.WalkSpeed * CONFIG.SpeedFloorFactor, CONFIG.MinSpeedFloor)
end

local function trackSpeed(headroom)
    local floor = speedFloor()
    return math.clamp(math.max(floor, observedSpeed * headroom), floor, CONFIG.MaxTrackSpeed)
end

local function observe(realPos, dt)
    if lastRealPos then
        local instant = math.min(mag(sub(realPos, lastRealPos)) / dt, CONFIG.MaxTrackSpeed)
        instantSpeed  = instant
        observedSpeed += (instant - observedSpeed) * math.min(1, dt * 8)
    end
    lastRealPos = realPos
end

-- SHADOW's budget: instantaneous, not smoothed.
local function shadowSpeedBudget()
    local floor = speedFloor()
    return math.clamp(math.max(floor, instantSpeed * 1.05), floor, CONFIG.MaxTrackSpeed)
end

local function chase(targetPos, maxSpeed, dt)
    local delta = sub(targetPos, serverPos)
    local dist  = mag(delta)
    local step  = math.min(dist, maxSpeed * dt)
    local pos   = dist > 1e-4 and add(serverPos, mul(unit(delta), step)) or targetPos
    local moved = mag(sub(pos, serverPos))
    serverPos = pos
    return dist - step, moved
end

local function leash(realPos, targetPos)
    local off = sub(realPos, targetPos)
    if mag(off) > CONFIG.MaxGap then
        return sub(realPos, mul(unit(off), CONFIG.MaxGap))
    end
    return targetPos
end

local fail = 0
local function check(cond, msg)
    if not cond then fail += 1 print("FAIL: " .. msg) end
end

local dt = 1/60

local function reset()
    serverPos, observedSpeed, lastRealPos = V(0,0,0), 0, nil
end

-- Run the player at `speed` for `secs`, ANCHOR mode with leash. Returns the
-- worst speed serverPos ever travelled at, and the final gap.
local function run(speed, secs)
    reset()
    local realPos, worst = V(0,0,0), 0
    for _ = 1, math.floor(secs / dt) do
        realPos = add(realPos, V(speed * dt, 0, 0))
        observe(realPos, dt)
        local target = leash(realPos, V(0,0,0))
        local _, moved = chase(target, trackSpeed(1.05), dt)
        worst = math.max(worst, moved / dt)
    end
    return worst, mag(sub(realPos, serverPos))
end

-- 1. Walking speed: leash holds, serverPos never beats its own budget.
local worst, gap = run(16, 30)
check(gap <= CONFIG.MaxGap + 1e-3, string.format("walk: gap %.2f > MaxGap", gap))
check(worst <= speedFloor() + 1e-6, string.format("walk: speed %.2f > floor", worst))

-- 2. Sprinting well over the floor — the case that failed with a fixed cap.
worst, gap = run(200, 60)
check(gap <= CONFIG.MaxGap + 1e-3, string.format("sprint: gap %.2f > MaxGap", gap))
check(worst <= 200 * 1.05 + 1, string.format("sprint: serverPos outran the player: %.2f", worst))

-- 3. Above the ceiling the gap is allowed to grow, but the speed stays capped.
worst, gap = run(600, 20)
check(worst <= CONFIG.MaxTrackSpeed + 1e-6,
    string.format("over-ceiling: speed %.2f > MaxTrackSpeed", worst))
check(gap > CONFIG.MaxGap, "over-ceiling: expected the gap to grow past the leash")

-- 4. Resync converges while the player is standing still.
reset()
serverPos = V(0,0,0)
local realPos, steps, worstR, remaining = V(500,0,0), 0, 0, math.huge
while remaining > CONFIG.ResyncTolerance and steps < 200000 do
    observe(realPos, dt)
    local r, moved = chase(realPos, math.max(speedFloor(), trackSpeed(1.15)), dt)
    remaining, worstR, steps = r, math.max(worstR, moved / dt), steps + 1
end
check(remaining <= CONFIG.ResyncTolerance, "resync (idle) did not converge")
check(worstR <= speedFloor() + 1e-6, string.format("resync (idle) speed %.2f", worstR))
print(string.format("resync of 500 studs while idle: %.2fs", steps * dt))

-- 5. Resync converges even while the player keeps sprinting away. This is the
--    case the 1.15 headroom exists for.
-- Build a genuine gap first by sprinting with the leash on, then resync while
-- still sprinting — otherwise the gap starts at zero and the test proves nothing.
reset()
realPos = V(0,0,0)
for _ = 1, math.floor(20 / dt) do
    realPos = add(realPos, V(120 * dt, 0, 0))
    observe(realPos, dt)
    chase(leash(realPos, V(0,0,0)), trackSpeed(1.05), dt)
end
local startGap = mag(sub(realPos, serverPos))
check(startGap > CONFIG.MaxGap * 0.9,
    string.format("sprint resync setup: expected a real gap, got %.2f", startGap))

steps, remaining = 0, math.huge
while remaining > CONFIG.ResyncTolerance and steps < 200000 do
    realPos = add(realPos, V(120 * dt, 0, 0))
    observe(realPos, dt)
    local r = chase(realPos, math.max(speedFloor(), trackSpeed(1.15)), dt)
    remaining, steps = r, steps + 1
end
check(remaining <= CONFIG.ResyncTolerance, "resync (while sprinting) did not converge")
print(string.format("resync of %.0f studs while sprinting at 120: %.2fs", startGap, steps * dt))

-- 6. No jump on the first frame from a cold start far from the target.
reset()
local _, firstMove = chase(V(1000,0,0), trackSpeed(1.05), dt)
check(firstMove <= speedFloor() * dt + 1e-6,
    string.format("first frame jumped %.3f studs", firstMove))

-- 7. Clamped lag-spike frame stays bounded.
reset()
local _, spikeMove = chase(V(1000,0,0), trackSpeed(1.05), 0.25)
check(spikeMove <= speedFloor() * 0.25 + 1e-6,
    string.format("lag-spike frame moved %.3f studs", spikeMove))

-- 8. Zero-distance chase produces no NaN and no motion.
reset()
serverPos = V(5,5,5)
local _, zeroMove = chase(V(5,5,5), trackSpeed(1.05), dt)
check(zeroMove == zeroMove, "NaN on zero-distance chase")
check(zeroMove < 1e-6, "moved on a zero-distance chase")

-- 9. A single glitched frame must not unlock a large move.
reset()
observe(V(0,0,0), dt)
observe(V(5000,0,0), dt)           -- one absurd frame
local budget = trackSpeed(1.05)
check(budget <= CONFIG.MaxTrackSpeed + 1e-6, "glitch frame exceeded ceiling")
print(string.format("budget after one 5000-stud glitch frame: %.1f studs/s", budget))

-- 10. SHADOW mode: once the rigid offset is established, serverPos travels at
--     exactly the player's speed. No catch-up burst exists for a speed check
--     to read — this is the property ANCHOR cannot offer, because its leash
--     has to accelerate from a standstill to reel the gap back in.
local function runShadow(playerSpeed, secs)
    reset()
    local realPos = V(0,0,0)
    serverPos = add(realPos, CONFIG.ShadowOffset)
    local settle, worstAfter, gapAfter = math.floor(0.5 / dt), 0, 0
    for i = 1, math.floor(secs / dt) do
        realPos = add(realPos, V(playerSpeed * dt, 0, 0))
        observe(realPos, dt)
        local _, moved = chase(add(realPos, CONFIG.ShadowOffset), shadowSpeedBudget(), dt)
        if i > settle then
            worstAfter = math.max(worstAfter, moved / dt)
            gapAfter   = math.max(gapAfter, mag(sub(realPos, serverPos)))
        end
    end
    return worstAfter, gapAfter
end

local shadowSpeed, shadowGap = runShadow(16, 20)
check(shadowSpeed <= 16 + 1e-3,
    string.format("shadow: serverPos moved at %.3f, faster than the player's 16", shadowSpeed))
check(math.abs(shadowGap - mag(CONFIG.ShadowOffset)) < 1e-3,
    string.format("shadow: gap %.3f drifted from the rigid offset %.3f",
        shadowGap, mag(CONFIG.ShadowOffset)))

-- Holds when sprinting well past the floor too.
shadowSpeed, shadowGap = runShadow(120, 20)
check(shadowSpeed <= 120 + 1e-3,
    string.format("shadow sprint: serverPos moved at %.3f vs player 120", shadowSpeed))
check(math.abs(shadowGap - mag(CONFIG.ShadowOffset)) < 1e-3,
    string.format("shadow sprint: gap %.3f drifted", shadowGap))
print(string.format("shadow: constant gap %.1f studs, serverPos speed == player speed",
    shadowGap))

-- 11. The floor must never exceed the player's own WalkSpeed at default
--     settings. A floor above WalkSpeed is exactly what a speed check reads
--     when the leash catches up.
check(speedFloor() <= CONFIG.WalkSpeed + 1e-6,
    string.format("floor %.1f exceeds WalkSpeed %.1f", speedFloor(), CONFIG.WalkSpeed))

-- And it must survive a WalkSpeed of 0 without stalling a resync at zero.
CONFIG.WalkSpeed = 0
check(speedFloor() >= CONFIG.MinSpeedFloor,
    "zero WalkSpeed collapsed the floor below MinSpeedFloor")
CONFIG.WalkSpeed = 16

print(fail == 0 and "ALL CHECKS PASSED" or (fail .. " CHECK(S) FAILED"))

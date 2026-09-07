--[[
    Desync.lua — Universal Roblox Desync

    You walk around normally. The humanoid is never modified, so movement,
    animations, collision and the camera stay entirely native. Only what the
    server receives is changed.

    The core invariant
    ------------------
    The position the server sees (`serverCF`) NEVER jumps. It is a simulated
    point that chases a target at a capped speed, always. Every teleport
    detector works the same way — magnitude(lastPos, newPos) / dt compared
    against a plausible maximum — so a position that only ever moves at a
    legitimate speed has nothing to flag, no matter how far it currently is
    from where you actually are.

    That single rule is what makes this usable in games that detect teleports.
    It is also why switching it off no longer snaps: instead of handing the
    server your real position in one frame, the script walks `serverCF` back
    to you at running speed and only then stops.

    Modes
    -----
    SHADOW  A rigid offset from where you actually are. The gap is constant,
            so serverCF moves at exactly your speed and no catch-up burst
            exists to be detected. Small enough to stay inside a game's
            interaction range, so your own attacks and interactions still
            land. Default.
    TRAIL   serverCF follows the path you actually walked, TrailLag seconds
            behind. Every position the server sees is one you genuinely
            occupied, in the order you occupied it — there is no artificial
            movement to detect at all.
    ANCHOR  serverCF is pinned where you switched on. Biggest gap, loudest:
            its leash has to accelerate from a standstill to reel you back in,
            and that acceleration is a speed signature the others lack.

    The server has one position for you, and range checks measure from it, so
    any gap large enough to stop incoming damage breaks your own outgoing
    reach by the same distance. SHADOW exists to keep the gap under that line.

    MaxGap is the leash. Games that snap you back are measuring the distance
    between where they think you are and where you claim to be; keeping the
    gap under that threshold is what stops the snap. Default 60 studs.

    Transports
    ----------
    native  Uses the executor's RakNet layer: physics packets are suppressed
            and the spoofed position is pushed directly. No local CFrame
            writes at all, so nothing client-side can observe the desync.
            Requires both a packet-drop function and rnet.sendphysics.
    swap    The portable fallback. Frame order on the client is

                RenderStepped -> render -> Stepped -> physics -> Heartbeat -> flush

            Heartbeat is the last thing before the engine transmits, so the
            real CFrame is saved and the spoofed one written there. It is then
            restored TWICE: at Stepped, which fires immediately before the
            physics step, and at RenderStepped, before the frame draws.

            Both restores are load-bearing. Physics is not locked to the
            render frame, and at 30fps the gap between the Heartbeat write and
            the next RenderStepped is a full 33ms of simulation — long enough
            for the engine to solve the character out of whatever the spoofed
            position is intersecting, which shows up as shaking. Restoring at
            Stepped is what guarantees physics only ever integrates from the
            real state.

    Toggle with the GUI button or [F]. Everything works from the GUI alone —
    no keyboard required.
--]]

local CONFIG = {
    ToggleKey = Enum.KeyCode.F,

    Mode = "SHADOW",    -- "SHADOW", "TRAIL" or "ANCHOR"

    -- SHADOW mode: a rigid offset from wherever you actually are.
    --
    -- The gap is constant, so serverCF's speed is identically your speed —
    -- there is no catch-up burst for a speed check to read, ever. And because
    -- the gap stays small it sits inside a game's interaction range, so your
    -- own attacks and interactions still land. That is the trade the other two
    -- modes cannot make: any gap large enough to protect you from incoming
    -- damage breaks your outgoing reach by exactly the same distance.
    --
    -- Horizontal, not vertical. A downward offset reads well on paper — it
    -- displaces you without changing horizontal distance to anything — but it
    -- puts the server-side root under the floor, and a game that notices you
    -- are inside terrain corrects it by ejecting you upward. A sideways offset
    -- keeps your ground height exactly right and costs only a few studs of
    -- range against a reach budget measured in tens.
    ShadowOffset = Vector3.new(4, 0, 0),

    -- The leash. How far the server's view of you may lag behind reality.
    -- Lower this until the game stops snapping you back.
    MaxGap = 60,        -- studs

    -- Floor on how fast serverCF may travel, as a multiple of your own
    -- WalkSpeed. A hardcoded number was wrong here: 32 studs/s is twice the
    -- default WalkSpeed, so any game watching speed sees the leash catch up at
    -- double your legitimate pace and calls it speeding. Deriving the floor
    -- from WalkSpeed means the server never sees you exceed a speed you are
    -- actually capable of. Raise it only if a game's threshold is looser.
    SpeedFloorFactor = 1.0,

    -- Absolute floor, so a WalkSpeed of 0 (frozen, seated, ragdolled) cannot
    -- stall a resync at zero speed forever.
    --
    -- Keep this BELOW the slowest speed the game can legitimately put you at,
    -- or it becomes the speed leak it exists to prevent. Games stack slow
    -- modifiers: a survival game measured here multiplies WalkSpeed by terrain
    -- (bedrock 0.35) and then divides by 3 for crouching, which turns a base
    -- of 16 into 1.87 studs/s. A floor of 8 would have moved serverCF at over
    -- four times the legitimate speed in that state.
    MinSpeedFloor = 1,   -- studs/s

    -- Hard ceiling on the speed serverCF will ever match, so a one-frame
    -- physics glitch or a game-scripted teleport can't unlock an arbitrarily
    -- fast move.
    MaxTrackSpeed = 250, -- studs/s

    -- TRAIL mode: how far behind your real path the server trails you.
    TrailLag = 1.5,     -- seconds

    -- Resync uses the same WalkSpeed-derived floor. Walking the gap back at
    -- your own walking speed is the most defensible thing the server can see.

    -- Consider the resync finished once the gap is under this.
    ResyncTolerance = 2, -- studs
}

-- ── Services ──────────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local StarterGui       = game:GetService("StarterGui")

local lp = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────
local PHASE_OFF, PHASE_ON, PHASE_RESYNC = "off", "on", "resync"
local phase = PHASE_OFF

local anchorCF = CFrame.new()   -- ANCHOR mode target
local serverCF = CFrame.new()   -- what the server sees; never jumps
local lastStep = os.clock()

-- Low-passed measure of how fast you are genuinely moving. serverCF is allowed
-- to match this, which is what lets the leash hold when you outrun the floor.
local observedSpeed = 0
local lastRealPos   = nil

-- Unsmoothed, clamped. SHADOW uses this rather than the low-passed figure:
-- a rigid offset needs exactly your instantaneous speed to hold station, and
-- feeding it a lagging estimate makes serverCF drop behind on acceleration and
-- then sprint to catch up — reintroducing the very burst SHADOW exists to
-- avoid.
local instantSpeed = 0

-- Genuine client state, borrowed only for the length of a replication flush
-- under the swap transport.
local realCF, realVel, realAngVel

local heartbeatConn = nil
local steppedConn   = nil
local root, humanoid

local RESTORE_BIND = "DesyncRestore"

-- ── RakNet backend detection ──────────────────────────────────────────────────
--
-- Executors expose this under different names and shapes. Everything here is
-- feature-detected and pcall-wrapped: if none of it exists the script falls
-- back to the swap transport and behaves identically, just less quietly.
--
-- Known surfaces:
--   raknet.desync(bool)              Velocity — physics-replication suppression
--   raknet.block(id, bool)           Velocity — block outgoing packets by ID
--   rnet.setfilter({bytes})          Celery — drop packets by leading byte
--   rnet.sendphysics(CFrame)         Celery — push a position to the server
--
-- 0x85 is ID_PHYSICS, the physics replication opcode.

local ID_PHYSICS = 0x85

local function globalTable(name)
    local ok, v = pcall(function()
        if getgenv then
            local g = getgenv()[name]
            if g ~= nil then return g end
        end
        return getfenv(0)[name]
    end)
    if ok and (type(v) == "table" or type(v) == "userdata") then return v end
    return nil
end

local function hasFn(t, name)
    if not t then return false end
    local ok, v = pcall(function() return t[name] end)
    return ok and type(v) == "function"
end

local Net = { drop = nil, sendPhysics = nil, label = "swap" }

local function detectBackend()
    local rk = globalTable("raknet")
    local rn = globalTable("rnet")

    if hasFn(rk, "desync") then
        Net.drop = function(on) pcall(function() rk.desync(on) end) end
    elseif hasFn(rk, "block") then
        Net.drop = function(on)
            pcall(function()
                if on then rk.block(ID_PHYSICS, true)
                elseif hasFn(rk, "unblock") then rk.unblock(ID_PHYSICS)
                else rk.block(ID_PHYSICS, false) end
            end)
        end
    elseif hasFn(rn, "setfilter") then
        Net.drop = function(on)
            pcall(function() rn.setfilter(on and { ID_PHYSICS } or {}) end)
        end
    end

    if hasFn(rn, "sendphysics") then
        Net.sendPhysics = function(cf) pcall(function() rn.sendphysics(cf) end) end
    end

    -- Native needs both halves: suppressing the real packets is only useful
    -- if something else is supplying a position, otherwise the server simply
    -- freezes at the last thing it heard and the resync has nothing to drive.
    Net.label = (Net.drop and Net.sendPhysics) and "native" or "swap"
end

detectBackend()

-- ── Path history ──────────────────────────────────────────────────────────────
-- TRAIL mode replays positions you genuinely occupied rather than inventing
-- any, so there is no synthetic movement for a heuristic to catch.

local trail = {}

local function pushTrail(pos, now)
    trail[#trail + 1] = { t = now, p = pos }
    local cutoff = now - (CONFIG.TrailLag + 2)
    local drop = 0
    while trail[drop + 1] and trail[drop + 1].t < cutoff do
        drop += 1
    end
    if drop > 0 then
        table.move(trail, drop + 1, #trail, 1)
        for i = #trail, #trail - drop + 1, -1 do trail[i] = nil end
    end
end

-- Interpolated position from `age` seconds ago.
local function trailPointAt(age, now)
    if #trail == 0 then return nil end
    local want = now - age
    for i = #trail, 1, -1 do
        if trail[i].t <= want then
            local a, b = trail[i], trail[i + 1]
            if not b then return a.p end
            local span = b.t - a.t
            if span <= 1e-6 then return a.p end
            return a.p:Lerp(b.p, math.clamp((want - a.t) / span, 0, 1))
        end
    end
    return trail[1].p
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local sg = Instance.new("ScreenGui")
sg.Name           = "DesyncGUI"
sg.ResetOnSpawn   = false
sg.IgnoreGuiInset = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

if not pcall(function() sg.Parent = game:GetService("CoreGui") end) then
    sg.Parent = lp:WaitForChild("PlayerGui")
end

local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(248, 196)
frame.Position         = UDim2.fromOffset(20, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel  = 0
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke", frame)
stroke.Color, stroke.Thickness = Color3.fromRGB(60, 60, 75), 1

local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
titleBar.BorderSizePixel  = 0
titleBar.Parent           = frame
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleSquare = Instance.new("Frame")
titleSquare.Size             = UDim2.new(1, 0, 0.5, 0)
titleSquare.Position         = UDim2.fromScale(0, 0.5)
titleSquare.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
titleSquare.BorderSizePixel  = 0
titleSquare.Parent           = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size                   = UDim2.new(1, -10, 1, 0)
titleLabel.Position               = UDim2.fromOffset(10, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font                   = Enum.Font.GothamBold
titleLabel.TextSize               = 13
titleLabel.TextColor3             = Color3.fromRGB(180, 180, 200)
titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
titleLabel.Text                   = "DESYNC"
titleLabel.Parent                 = titleBar

local function mkLabel(y, size, colour)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, -20, 0, 16)
    l.Position               = UDim2.fromOffset(10, y)
    l.BackgroundTransparency = 1
    l.Font                   = Enum.Font.Gotham
    l.TextSize               = size
    l.TextColor3             = colour
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.Parent                 = frame
    return l
end

local statusLabel = mkLabel(36, 12, Color3.fromRGB(120, 120, 140))
statusLabel.Text = "Status: Inactive"

local infoLabel = mkLabel(54, 11, Color3.fromRGB(95, 95, 115))
infoLabel.Text = "gap 0 · " .. Net.label

local function mkButton(y, h, text, size)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(1, -20, 0, h)
    b.Position         = UDim2.fromOffset(10, y)
    b.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    b.BorderSizePixel  = 0
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = size
    b.TextColor3       = Color3.fromRGB(200, 200, 220)
    b.Text             = text
    b.AutoButtonColor  = false
    b.Parent           = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local s = Instance.new("UIStroke", b)
    s.Color, s.Thickness = Color3.fromRGB(60, 60, 75), 1
    return b, s
end

-- 44px: a real touch target, since the GUI is the whole interface on mobile.
local btn, btnStroke = mkButton(78, 44, "ENABLE", 14)
local modeBtn, modeStroke = mkButton(130, 34, "Mode: TRAIL", 12)
local gapBtn, gapStroke   = mkButton(170, 0, "", 12)
gapBtn.Visible = false
gapStroke.Thickness = 0

local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)

btn.MouseEnter:Connect(function()
    if phase ~= PHASE_OFF then return end
    TweenService:Create(btn, tweenInfo, { BackgroundColor3 = Color3.fromRGB(50, 50, 65) }):Play()
end)
btn.MouseLeave:Connect(function()
    if phase ~= PHASE_OFF then return end
    TweenService:Create(btn, tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45) }):Play()
end)

local dragging, dragStart, startPos = false, nil, nil

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, startPos = true, input.Position, frame.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        frame.Position = UDim2.fromOffset(
            startPos.X.Offset + delta.X,
            startPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

local function updateUI()
    if phase == PHASE_ON then
        statusLabel.Text, statusLabel.TextColor3 = "Status: ACTIVE", Color3.fromRGB(80, 220, 100)
        btn.Text, btn.TextColor3 = "DISABLE", Color3.fromRGB(80, 220, 100)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(30, 90, 50) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(50, 160, 80) }):Play()
    elseif phase == PHASE_RESYNC then
        statusLabel.Text, statusLabel.TextColor3 = "Status: RESYNCING", Color3.fromRGB(230, 180, 90)
        btn.Text, btn.TextColor3 = "CANCEL", Color3.fromRGB(230, 180, 90)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(80, 60, 25) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(160, 120, 60) }):Play()
    else
        statusLabel.Text, statusLabel.TextColor3 = "Status: Inactive", Color3.fromRGB(120, 120, 140)
        btn.Text, btn.TextColor3 = "ENABLE", Color3.fromRGB(200, 200, 220)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(60, 60, 75) }):Play()
    end
end

local function updateModeUI()
    -- Colour tracks risk: green is reach-safe and speed-silent, blue is quiet
    -- but breaks your own reach, red is the loud one.
    local tint = {
        SHADOW = { Color3.fromRGB(140, 220, 160), Color3.fromRGB(60, 130, 80)  },
        TRAIL  = { Color3.fromRGB(140, 190, 230), Color3.fromRGB(70, 110, 150) },
        ANCHOR = { Color3.fromRGB(230, 140, 140), Color3.fromRGB(140, 70, 70)  },
    }
    local t = tint[CONFIG.Mode] or tint.SHADOW
    modeBtn.Text       = "Mode: " .. CONFIG.Mode
    modeBtn.TextColor3 = t[1]
    TweenService:Create(modeStroke, tweenInfo, { Color = t[2] }):Play()
end

-- ── Core ──────────────────────────────────────────────────────────────────────

local function alive()
    return root ~= nil and root.Parent ~= nil
end

local function rotationOf(cf)
    return cf - cf.Position
end

-- Where serverCF is trying to get to, before the leash is applied.
local function modeTarget(realPos, now)
    if CONFIG.Mode == "ANCHOR" then
        return anchorCF.Position
    end
    if CONFIG.Mode == "SHADOW" then
        -- Rigid offset. Once established, the target moves at exactly your
        -- speed, so serverCF does too and there is no burst to detect.
        return realPos + CONFIG.ShadowOffset
    end
    return trailPointAt(CONFIG.TrailLag, now) or realPos
end

-- How fast serverCF is allowed to travel this frame.
--
-- A fixed cap is the wrong rule. Cap and leash are in direct conflict: if you
-- move faster than the cap, serverCF cannot keep up and the gap grows without
-- bound, which is exactly the distance a snap-back check measures.
--
-- The resolution is that a speed *you actually achieved* is legitimate by
-- construction — the server watching you move at it has nothing to flag,
-- because you really did move that fast. So the budget is the greater of the
-- configured floor and your own smoothed speed, under a hard ceiling so a
-- single glitched frame can't unlock an arbitrarily fast move.
-- Derived from your own WalkSpeed rather than a fixed number, so the server
-- never sees you travel faster than you are genuinely capable of travelling.
local function speedFloor()
    local ws = 16
    if humanoid then
        local ok, v = pcall(function() return humanoid.WalkSpeed end)
        if ok and type(v) == "number" and v > 0 then ws = v end
    end
    return math.max(ws * CONFIG.SpeedFloorFactor, CONFIG.MinSpeedFloor)
end

local function trackSpeed(headroom)
    local floor = speedFloor()
    return math.clamp(
        math.max(floor, observedSpeed * headroom),
        floor,
        CONFIG.MaxTrackSpeed
    )
end

-- Move serverCF toward `targetPos`, never faster than `maxSpeed`. This is the
-- only place serverCF is ever written, which is what guarantees it cannot jump.
local function chase(targetPos, maxSpeed, dt, rot)
    local delta = targetPos - serverCF.Position
    local dist  = delta.Magnitude
    local step  = math.min(dist, maxSpeed * dt)
    local pos   = dist > 1e-4 and (serverCF.Position + delta.Unit * step) or targetPos
    serverCF = CFrame.new(pos) * rot
    return dist - step
end

-- Push serverCF to the server for this frame.
local function transmit()
    if Net.label == "native" then
        Net.sendPhysics(serverCF)
        return
    end
    -- swap: the real state is saved and restored around the flush
    realCF     = root.CFrame
    realVel    = root.AssemblyLinearVelocity
    realAngVel = root.AssemblyAngularVelocity

    root.CFrame                  = serverCF
    root.AssemblyLinearVelocity  = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

-- Put the genuine state back. Called from two places, and it needs both.
--
-- Physics is NOT locked to the render frame. The window between the Heartbeat
-- write and the next RenderStepped is one whole frame long — 33ms at the 30fps
-- a phone or tablet actually runs at — and the engine steps physics inside it.
-- With only the RenderStepped restore the character genuinely spends that time
-- at the spoofed position: SHADOW's downward offset puts the root under the
-- floor, the solver ejects the penetrating assembly, the humanoid flips to
-- Freefall, and the character shakes in the air.
--
-- Stepped fires immediately before the physics step, so restoring there is
-- what actually guarantees physics only ever integrates from the real state,
-- at any frame rate. The RenderStepped restore stays because it is what
-- guarantees the camera and the frame draw from the real state.
local function restoreReal()
    if Net.label == "native" then return end
    if not alive() or not realCF then return end
    root.CFrame                  = realCF
    root.AssemblyLinearVelocity  = realVel or Vector3.zero
    root.AssemblyAngularVelocity = realAngVel or Vector3.zero
end

local uiClock = 0

local function onHeartbeat()
    if phase == PHASE_OFF or not alive() then return end

    local now = os.clock()
    local dt  = math.min(now - lastStep, 0.25)
    lastStep  = now

    local realPos = root.CFrame.Position
    local rot     = rotationOf(root.CFrame)
    pushTrail(realPos, now)

    -- Smoothed real speed. Low-passed so a single spiked frame doesn't grant
    -- serverCF a large move, but responsive enough to track a sprint.
    if lastRealPos then
        -- Clamp the sample before it enters the filter, not just the result.
        -- A game-scripted teleport is one frame of effectively infinite speed,
        -- and without this it drags the average to the ceiling on its own.
        local instant = math.min(
            (realPos - lastRealPos).Magnitude / dt,
            CONFIG.MaxTrackSpeed
        )
        instantSpeed  = instant
        observedSpeed += (instant - observedSpeed) * math.min(1, dt * 8)
    end
    lastRealPos = realPos

    local targetPos, speed

    if phase == PHASE_RESYNC then
        -- Needs headroom over your current speed, otherwise a resync started
        -- while you are still running never converges.
        targetPos = realPos
        speed     = trackSpeed(1.15)
    else
        targetPos = modeTarget(realPos, now)
        if CONFIG.Mode == "SHADOW" then
            -- Mirror your motion 1:1. Steady state, serverCF's speed is
            -- identically yours; the 1.05 only closes residual rounding.
            local floor = speedFloor()
            speed = math.clamp(
                math.max(floor, instantSpeed * 1.05), floor, CONFIG.MaxTrackSpeed
            )
        else
            speed = trackSpeed(1.05)
        end

        -- The leash. Pull the target to within MaxGap of where you actually
        -- are, so the distance the game measures never crosses its threshold.
        -- Applied to the target rather than to serverCF itself, so the move
        -- toward it still goes through the speed cap.
        local off = realPos - targetPos
        if off.Magnitude > CONFIG.MaxGap then
            targetPos = realPos - off.Unit * CONFIG.MaxGap
        end
    end

    local remaining = chase(targetPos, speed, dt, rot)

    if phase == PHASE_RESYNC and remaining <= CONFIG.ResyncTolerance then
        -- Caught up. Stop touching anything.
        phase = PHASE_OFF
        restoreReal()
        realCF, realVel, realAngVel = nil, nil, nil
        if Net.drop then Net.drop(false) end
        pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
        if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
        if steppedConn then steppedConn:Disconnect(); steppedConn = nil end
        updateUI()
        infoLabel.Text = "gap 0 · " .. Net.label
        return
    end

    transmit()

    uiClock += dt
    if uiClock >= 0.1 then
        uiClock = 0
        infoLabel.Text = string.format(
            "gap %d · %s", (realPos - serverCF.Position).Magnitude, Net.label
        )
    end
end

local function startLoops()
    if heartbeatConn then return end
    lastStep = os.clock()
    heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
    -- Pre-physics restore. This is the one that stops the character being
    -- simulated at the spoofed position on a low frame rate.
    steppedConn = RunService.Stepped:Connect(restoreReal)
    -- Pre-render restore, so the camera and the frame draw from the real state.
    RunService:BindToRenderStep(RESTORE_BIND, Enum.RenderPriority.First.Value, restoreReal)
end

local function enable()
    if phase == PHASE_ON then return end

    if not alive() or not humanoid then
        statusLabel.Text       = "Status: no character"
        statusLabel.TextColor3 = Color3.fromRGB(220, 160, 60)
        return
    end

    -- Re-enabling mid-resync continues from where the server currently is
    -- rather than re-anchoring, so there is still no discontinuity.
    if phase == PHASE_OFF then
        serverCF = root.CFrame
        table.clear(trail)
        observedSpeed, lastRealPos = 0, nil
    end

    anchorCF = root.CFrame
    phase    = PHASE_ON

    if Net.drop then Net.drop(true) end
    startLoops()
    updateUI()

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = CONFIG.Mode .. " · " .. Net.label, Duration = 2,
        })
    end)
end

-- Switching off does not hand the server your real position. It walks
-- serverCF back to you at walking speed and only stops once it arrives, so the
-- position history stays continuous and there is no teleport to detect.
local function disable()
    if phase ~= PHASE_ON then return end
    phase = PHASE_RESYNC

    -- Native suppression has to come off now: the resync needs the real
    -- packets flowing again once serverCF converges, and sendphysics keeps
    -- driving the position until then.
    if Net.drop and Net.label ~= "native" then Net.drop(false) end

    updateUI()
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = "Resyncing — walking the gap back", Duration = 2,
        })
    end)
end

local function teardown()
    phase = PHASE_OFF
    pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
    if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
    if steppedConn then steppedConn:Disconnect(); steppedConn = nil end
    if Net.drop then Net.drop(false) end
end

local function toggle()
    if phase == PHASE_ON then
        disable()
    elseif phase == PHASE_RESYNC then
        -- Cancelling a resync snaps, which is the thing this exists to avoid.
        -- Go back to desyncing instead; the gap simply reopens from here.
        phase = PHASE_ON
        if Net.drop then Net.drop(true) end
        updateUI()
    else
        enable()
    end
end

-- ── Character binding ─────────────────────────────────────────────────────────
local function bindCharacter(c)
    root     = c:WaitForChild("HumanoidRootPart")
    humanoid = c:WaitForChild("Humanoid")
    serverCF = root.CFrame
end

task.spawn(function()
    bindCharacter(lp.Character or lp.CharacterAdded:Wait())
end)

lp.CharacterAdded:Connect(function(newChar)
    teardown()
    realCF, realVel, realAngVel = nil, nil, nil
    root, humanoid = nil, nil
    table.clear(trail)
    updateUI()
    bindCharacter(newChar)
end)

-- ── Input ─────────────────────────────────────────────────────────────────────
-- Activated rather than MouseButton1Click: it covers taps as well as clicks.
btn.Activated:Connect(toggle)

modeBtn.Activated:Connect(function()
    local order = { SHADOW = "TRAIL", TRAIL = "ANCHOR", ANCHOR = "SHADOW" }
    CONFIG.Mode = order[CONFIG.Mode] or "SHADOW"
    if phase == PHASE_ON then anchorCF = alive() and root.CFrame or anchorCF end
    updateModeUI()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.ToggleKey then toggle() end
end)

updateModeUI()
updateUI()

-- ── Public API ────────────────────────────────────────────────────────────────
return {
    enable   = enable,
    disable  = disable,
    toggle   = toggle,
    phase    = function() return phase end,
    gap      = function()
        if not alive() then return 0 end
        return (root.CFrame.Position - serverCF.Position).Magnitude
    end,
    backend  = function() return Net.label end,
    config   = CONFIG,
}

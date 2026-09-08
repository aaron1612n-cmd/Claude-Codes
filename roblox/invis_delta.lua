--=====================================================================
-- roblox/invis_delta.lua
-- Delta executor — four independent invisibility methods, GUI toggles.
--
--   1. Transparency  direct Transparency + LTM writes          [LOCAL ONLY]
--   2. Joint Crush   Motor6D.Transform collapse                [animation net]
--   3. Net Desync    simulation-radius ownership drop          [physics net]
--   4. Under Map     rig break + phase-split CFrame drop       [physics net]
--
-- What crosses to the server from a client is narrow: physics (CFrame /
-- velocity) on assemblies the client owns, and the animation channel
-- (Motor6D.Transform). Plain property writes — Transparency, Color, Size,
-- Decal.Transparency — never replicate. M1 is therefore self-cloaking
-- only, and is labelled as such. M2/M3/M4 ride the two channels that do
-- replicate, so other players are affected.
--
-- M4 is the one to reach for: HumanoidRootPart is never moved, so the
-- server-side hitbox, tool origin and movement all stay at your real
-- position while the visible body sits under the map.
--=====================================================================

local CONFIG = {
    GUI_NAME      = "InvisGUI",
    RESYNC_KEY    = Enum.KeyCode.R,   -- M3: burst-resync so a swing lands where you stand
    RESYNC_FRAMES = 6,                -- how many frames ownership is handed back
    EFFECT_PERIOD = 0.5,              -- seconds between effect re-assert passes
    HIDE_NAMETAG  = true,             -- M1/M4 also kill the humanoid name/health display
    UNDER_DEPTH   = 512,              -- M4: studs below the root the body is parked at
    KEEP_TOOL_UP  = true,             -- M4: leave equipped tool parts at the real position
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer

-- ── executor env (undefined globals resolve to nil, never throw) ──────────────

local gethui            = gethui
local sethiddenproperty = sethiddenproperty

--=====================================================================
-- Tracker — one live set of "my visible instances", shared by every
-- method. Replaces the per-frame GetDescendants() scan: parts are
-- ingested once on spawn and incrementally as they replicate in.
--=====================================================================

local EFFECT_PROP = {
    Decal = "Transparency", Texture = "Transparency",
    ParticleEmitter = "Enabled", Trail = "Enabled", Beam = "Enabled",
    Smoke = "Enabled", Fire = "Enabled", Sparkles = "Enabled",
    BillboardGui = "Enabled", SurfaceGui = "Enabled",
}

local Tracker = {
    parts   = {},   -- [BasePart]  = true   (non-HRP)
    effects = {},   -- [Instance]  = propertyName
    motors  = {},   -- [Motor6D]   = true
    char    = nil,
    hum     = nil,
    hrp     = nil,
    onAdd   = {},   -- array of fn(inst, kind)
    onChar  = {},   -- array of fn(char)
    _conns  = {},
    _users  = 0,
}

local function classify(inst)
    if inst:IsA("BasePart") then
        return inst.Name ~= "HumanoidRootPart" and "part" or nil
    end
    if inst:IsA("Motor6D") then return "motor" end
    return EFFECT_PROP[inst.ClassName] and "effect" or nil
end

function Tracker._ingest(inst)
    local kind = classify(inst)
    if not kind then return end
    if kind == "part" then
        Tracker.parts[inst] = true
    elseif kind == "motor" then
        Tracker.motors[inst] = true
    else
        Tracker.effects[inst] = EFFECT_PROP[inst.ClassName]
    end
    for _, fn in ipairs(Tracker.onAdd) do
        local ok, err = pcall(fn, inst, kind)
        if not ok then warn("[Invis] onAdd:", err) end
    end
end

function Tracker._drop()
    for _, c in ipairs(Tracker._conns) do c:Disconnect() end
    table.clear(Tracker._conns)
end

function Tracker._bind(char)
    Tracker._drop()
    Tracker.char = char
    Tracker.hum  = char:FindFirstChildOfClass("Humanoid")
    Tracker.hrp  = char:FindFirstChild("HumanoidRootPart")
    table.clear(Tracker.parts)
    table.clear(Tracker.effects)
    table.clear(Tracker.motors)

    for _, d in ipairs(char:GetDescendants()) do
        Tracker._ingest(d)
    end

    table.insert(Tracker._conns, char.DescendantAdded:Connect(Tracker._ingest))
    table.insert(Tracker._conns, char.DescendantRemoving:Connect(function(inst)
        Tracker.parts[inst]   = nil
        Tracker.effects[inst] = nil
        Tracker.motors[inst]  = nil
    end))

    for _, fn in ipairs(Tracker.onChar) do
        local ok, err = pcall(fn, char)
        if not ok then warn("[Invis] onChar:", err) end
    end
end

function Tracker.retain()
    Tracker._users += 1
    if Tracker._users > 1 then return end
    if lp.Character then Tracker._bind(lp.Character) end
    Tracker._charConn = lp.CharacterAdded:Connect(function(char)
        char:WaitForChild("HumanoidRootPart", 10)
        task.wait()
        Tracker._bind(char)
    end)
end

function Tracker.release()
    Tracker._users -= 1
    if Tracker._users > 0 then return end
    if Tracker._charConn then Tracker._charConn:Disconnect() end
    Tracker._charConn = nil
    Tracker._drop()
    table.clear(Tracker.parts)
    table.clear(Tracker.effects)
    table.clear(Tracker.motors)
    Tracker.char, Tracker.hum, Tracker.hrp = nil, nil, nil
end

-- Walk up from a part to see whether it belongs to an equipped Tool.
-- Tools parent under the character on equip, so the walk is 2-3 deep.
local function inTool(inst)
    local p = inst.Parent
    while p and p ~= Tracker.char and p ~= workspace do
        if p:IsA("Tool") then return true end
        p = p.Parent
    end
    return false
end

local function hideNametag(store)
    local hum = Tracker.hum
    if not (CONFIG.HIDE_NAMETAG and hum) then return end
    if store[hum] == nil then
        store[hum] = {
            hum.DisplayDistanceType, hum.NameDisplayDistance, hum.HealthDisplayDistance,
        }
    end
    hum.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.None
    hum.NameDisplayDistance   = 0
    hum.HealthDisplayDistance = 0
end

local function restoreNametag(saved)
    local hum = Tracker.hum
    if not (hum and saved) then return end
    hum.DisplayDistanceType   = saved[1]
    hum.NameDisplayDistance   = saved[2]
    hum.HealthDisplayDistance = saved[3]
end

--=====================================================================
-- GUI
--=====================================================================

local host = (gethui and gethui()) or game:GetService("CoreGui")
local old  = host:FindFirstChild(CONFIG.GUI_NAME)
if old then old:Destroy() end

local sg = Instance.new("ScreenGui")
sg.Name           = CONFIG.GUI_NAME
sg.ResetOnSpawn   = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent         = host

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 250, 0, 202)
frame.Position         = UDim2.new(0, 12, 0.5, -101)
frame.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Draggable        = true
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size                   = UDim2.new(1, 0, 0, 26)
titleLbl.BackgroundTransparency = 1
titleLbl.Text                   = "Invisibility  ·  Delta"
titleLbl.TextColor3             = Color3.fromRGB(215, 215, 220)
titleLbl.Font                   = Enum.Font.GothamBold
titleLbl.TextSize               = 12
titleLbl.Parent                 = frame

local OFF_BG = Color3.fromRGB(38, 38, 42)

local function makeBtn(label, yOff, onColor)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -20, 0, 32)
    btn.Position         = UDim2.new(0, 10, 0, yOff)
    btn.BackgroundColor3 = OFF_BG
    btn.BorderSizePixel  = 0
    btn.AutoButtonColor  = false
    btn.Text             = label .. "   OFF"
    btn.TextColor3       = Color3.fromRGB(172, 172, 178)
    btn.Font             = Enum.Font.Gotham
    btn.TextSize         = 12
    btn.Parent           = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    return btn, function(on)
        btn.Text             = label .. (on and "   ON" or "   OFF")
        btn.BackgroundColor3 = on and onColor or OFF_BG
        btn.TextColor3       = on and Color3.fromRGB(245, 245, 245)
                                  or Color3.fromRGB(172, 172, 178)
    end
end

local btn1, paint1 = makeBtn("Transparency  (self)", 30,  Color3.fromRGB(0, 132, 62))
local btn2, paint2 = makeBtn("Joint Crush",         66,  Color3.fromRGB(0, 92, 178))
local btn3, paint3 = makeBtn("Net Desync",          102, Color3.fromRGB(150, 74, 0))
local btn4, paint4 = makeBtn("Under Map",           138, Color3.fromRGB(132, 0, 78))

local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -20, 0, 20)
status.Position               = UDim2.new(0, 10, 0, 174)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = Color3.fromRGB(118, 118, 126)
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Font                   = Enum.Font.Code
status.TextSize               = 11
status.Parent                 = frame

--=====================================================================
-- Method 1 — Transparency + LocalTransparencyModifier   [LOCAL ONLY]
--
-- Both properties are client-render state. Roblox replicates property
-- changes server->client only, so nothing here reaches another player;
-- this hides your body from your own camera and nothing more. Kept
-- because it is the only method that leaves the rig completely intact,
-- which matters when a game validates its own character every frame.
--
-- Runs at RenderPriority.Last+1: LTM is a render-frame property, so the
-- write has to land after the renderer and the Humanoid have had their
-- pass, otherwise a camera/state change silently clears it. Writes are
-- gated on a value check, so a steady frame costs one compare per part
-- instead of one property write per part.
--=====================================================================

local m1On, m1Orig, m1Transp, m1EffectClock = false, {}, {}, 0

local function m1HideEffect(inst)
    local prop = Tracker.effects[inst]
    if not prop then return end
    if m1Orig[inst] == nil then m1Orig[inst] = inst[prop] end
    local want = (prop == "Transparency") and 1 or false
    if inst[prop] ~= want then inst[prop] = want end
end

local function m1HidePart(part)
    if m1Transp[part] == nil then m1Transp[part] = part.Transparency end
    if part.Transparency ~= 1 then part.Transparency = 1 end
    if part.LocalTransparencyModifier ~= 1 then part.LocalTransparencyModifier = 1 end
end

local function m1OnAdd(inst, kind)
    if not m1On then return end
    if kind == "part" then
        m1HidePart(inst)
    elseif kind == "effect" then
        m1HideEffect(inst)
    end
end

local function m1OnChar()
    if not m1On then return end
    hideNametag(m1Orig)
end

local function m1Step(dt)
    for part in pairs(Tracker.parts) do m1HidePart(part) end

    m1EffectClock += dt
    if m1EffectClock >= CONFIG.EFFECT_PERIOD then
        m1EffectClock = 0
        for inst in pairs(Tracker.effects) do m1HideEffect(inst) end
        hideNametag(m1Orig)
    end
end

local function m1Start()
    m1On = true
    Tracker.retain()
    for part in pairs(Tracker.parts) do m1HidePart(part) end
    for inst in pairs(Tracker.effects) do m1HideEffect(inst) end
    hideNametag(m1Orig)
    RunService:BindToRenderStep("InvisM1", Enum.RenderPriority.Last.Value + 1, m1Step)
end

local function m1Stop()
    m1On = false
    pcall(function() RunService:UnbindFromRenderStep("InvisM1") end)

    for part, t in pairs(m1Transp) do
        if part.Parent then
            part.Transparency = t
            part.LocalTransparencyModifier = 0
        end
    end
    table.clear(m1Transp)

    for inst, saved in pairs(m1Orig) do
        if inst.Parent then
            if typeof(saved) == "table" then
                restoreNametag(saved)
            else
                local prop = Tracker.effects[inst]
                if prop then inst[prop] = saved end
            end
        end
    end
    table.clear(m1Orig)
    Tracker.release()
end

--=====================================================================
-- Method 2 — Motor6D.Transform collapse            [animation channel]
--
-- Motor6D world math is:
--     Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()
--
-- Solving that for Part1.CFrame == Part0.CFrame gives
--     Transform = C0:Inverse() * C1
-- which drops every limb exactly onto its parent joint's origin. Applied
-- across the whole rig it folds the character into a single point at the
-- root, so there is no silhouette left to see.
--
-- Transform is the value the Animator writes each frame and is carried on
-- the animation replication channel — the same path that lets other
-- players watch you walk. Writing it on Heartbeat lands after the
-- Animator's step-phase write and immediately before the replication
-- snapshot, so ours is the value that goes out.
--
-- Whether a raw script write is picked up by that channel depends on the
-- engine tagging the property dirty for the animation replicator, which
-- is not documented and does vary by game. Treat M2 as the cheap attempt
-- that leaves the rig intact; M4 is the reliable one.
--
-- LTM is pinned locally so you are not staring at the folded blob.
--=====================================================================

local m2On, m2Conn = false, nil

local function m2Fold()
    for motor in pairs(Tracker.motors) do
        if motor.Parent then
            motor.Transform = motor.C0:Inverse() * motor.C1
        end
    end
    for part in pairs(Tracker.parts) do
        if part.LocalTransparencyModifier ~= 1 then
            part.LocalTransparencyModifier = 1
        end
    end
end

local function m2Start()
    if m2On then return end
    m2On = true
    Tracker.retain()
    m2Conn = RunService.Heartbeat:Connect(m2Fold)
end

local function m2Stop()
    if not m2On then return end
    m2On = false
    if m2Conn then m2Conn:Disconnect() end
    m2Conn = nil

    -- The Animator overwrites Transform on its next step, so the rig
    -- recovers on its own; only the local render override needs undoing.
    for part in pairs(Tracker.parts) do
        if part.Parent then part.LocalTransparencyModifier = 0 end
    end
    Tracker.release()
end

--=====================================================================
-- Method 3 — network ownership desync                 [physics channel]
--
-- Dropping SimulationRadius to 0 makes the client stop claiming physics
-- ownership of its own character, so it stops pushing CFrame updates.
-- The server keeps the last replicated state while the client carries on
-- simulating and rendering locally — other players watch a stale copy at
-- the anchor while you walk away from it.
--
-- The server re-grants ownership on its own cadence, so the radius is
-- re-asserted every Heartbeat rather than set once.
--
-- Because the server's copy of you is frozen at the anchor, a tool swing
-- would otherwise resolve from there. RESYNC_KEY hands ownership back for
-- a few frames: your real position snaps to where you actually are, the
-- hit registers, and the anchor re-captures at the new spot.
--=====================================================================

local m3On, m3Conn = false, nil
local m3Anchor, m3Resync, m3Drift = nil, 0, 0

local function m3Radius(v)
    if not sethiddenproperty then return end
    pcall(sethiddenproperty, lp, "SimulationRadius", v)
    pcall(sethiddenproperty, lp, "MaximumSimulationRadius", v)
end

local function m3HRP()
    local char = lp.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function m3Start()
    m3On = true
    local hrp = m3HRP()
    m3Anchor  = hrp and hrp.Position or nil
    m3Resync  = 0

    m3Conn = RunService.Heartbeat:Connect(function()
        local hrp = m3HRP()

        if m3Resync > 0 then
            m3Resync -= 1
            m3Radius(math.huge)          -- ownership back: position + hits land
            if m3Resync == 0 and hrp then
                m3Anchor = hrp.Position  -- re-anchor at the resynced spot
            end
            return
        end

        m3Radius(0)
        if hrp and m3Anchor then
            m3Drift = (hrp.Position - m3Anchor).Magnitude
        end
    end)
end

local function m3Stop()
    m3On = false
    if m3Conn then m3Conn:Disconnect() end
    m3Conn = nil
    m3Radius(math.huge)   -- restore normal ownership
    m3Anchor, m3Drift, m3Resync = nil, 0, 0
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe or not m3On then return end
    if input.KeyCode == CONFIG.RESYNC_KEY then
        m3Resync = CONFIG.RESYNC_FRAMES
    end
end)

--=====================================================================
-- Method 4 — rig break + phase-split CFrame drop      [physics channel]
--
-- A rigged character is ONE physics assembly rooted at HumanoidRootPart,
-- so only the root's CFrame replicates and limb writes are discarded —
-- which is why naively CFraming a limb does nothing to other clients.
-- Disabling every Motor6D promotes each limb to its own assembly, and a
-- client-owned assembly replicates its own CFrame. Now limb writes land.
--
-- The frame order Roblox runs is:
--     RenderStepped -> render -> Stepped -> physics -> Heartbeat -> replicate
--
-- so the two writes can disagree on purpose:
--     Heartbeat      -> park the body UNDER_DEPTH studs down   (replicated)
--     RenderStepped  -> restore the captured pose at the root  (rendered)
--
-- Other players read the Heartbeat value and see empty ground. Your own
-- camera reads the RenderStepped value and sees your body where it should
-- be. HumanoidRootPart is never touched by any of this, so the collision
-- capsule, the tool origin, movement and every server-side hit test stay
-- exactly where you are standing — you can hit people above you.
--
-- Equipped tool parts are exempted (KEEP_TOOL_UP): a touch-damage weapon
-- welded to a hand that just went underground would only ever hit dirt.
-- The cost is a floating weapon visible to others, which is the honest
-- trade for having your swings connect.
--
-- The pose is captured once at toggle-on because the rig is broken, so
-- your body is a fixed stance rather than an animated one. Limbs are set
-- CanCollide=false and have their velocity zeroed each frame so loose
-- assemblies cannot shove the root around or snag on the map.
--=====================================================================

local m4On = false
local m4Pose, m4Motors, m4Collide, m4Orig = {}, {}, {}, {}
local m4Render, m4Heart = nil, nil

local ZERO3 = Vector3.new(0, 0, 0)

local function m4Capture(char)
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    -- Pose first: once the motors are off the limbs start drifting.
    local inv = hrp.CFrame:Inverse()
    table.clear(m4Pose)
    table.clear(m4Collide)
    for part in pairs(Tracker.parts) do
        if not (CONFIG.KEEP_TOOL_UP and inTool(part)) then
            m4Pose[part]    = inv * part.CFrame
            m4Collide[part] = part.CanCollide
            part.CanCollide = false
        end
    end

    table.clear(m4Motors)
    for motor in pairs(Tracker.motors) do
        if motor.Enabled then
            m4Motors[#m4Motors + 1] = motor
            motor.Enabled = false
        end
    end

    hideNametag(m4Orig)
    return true
end

local function m4Restore()
    for _, motor in ipairs(m4Motors) do
        if motor.Parent then motor.Enabled = true end
    end
    table.clear(m4Motors)

    for part, collide in pairs(m4Collide) do
        if part.Parent then part.CanCollide = collide end
    end
    table.clear(m4Collide)
    table.clear(m4Pose)

    for _, saved in pairs(m4Orig) do restoreNametag(saved) end
    table.clear(m4Orig)
end

-- Heartbeat: last write before the replication snapshot. This is the
-- body position every other client receives.
local function m4Down()
    local hrp = Tracker.hrp
    if not (hrp and hrp.Parent) then return end
    local under = CFrame.new(hrp.Position.X, hrp.Position.Y - CONFIG.UNDER_DEPTH, hrp.Position.Z)

    for part in pairs(Tracker.parts) do
        if not (CONFIG.KEEP_TOOL_UP and inTool(part)) then
            part.CFrame = under
            part.AssemblyLinearVelocity  = ZERO3
            part.AssemblyAngularVelocity = ZERO3
        end
    end
end

-- RenderStepped (Last+1, after camera and Humanoid): the pose your own
-- screen draws. Never replicated, because Heartbeat overwrites it before
-- the snapshot is taken.
local function m4Up()
    local hrp = Tracker.hrp
    if not (hrp and hrp.Parent) then return end
    local root = hrp.CFrame

    for part in pairs(Tracker.parts) do
        local pose = m4Pose[part]
        if pose then
            part.CFrame = root * pose
        elseif CONFIG.KEEP_TOOL_UP and inTool(part) then
            -- Equipped after capture: pin it just ahead of the root so a
            -- touch weapon still resolves at the surface.
            part.CFrame = root * CFrame.new(1, 0, -1.5)
        end
    end
end

local function m4OnAdd(inst, kind)
    if not (m4On and kind == "part") then return end
    local hrp = Tracker.hrp
    if not hrp then return end
    if CONFIG.KEEP_TOOL_UP and inTool(inst) then return end
    m4Pose[inst]    = hrp.CFrame:Inverse() * inst.CFrame
    m4Collide[inst] = inst.CanCollide
    inst.CanCollide = false
end

local function m4OnChar(char)
    if not m4On then return end
    m4Capture(char)
end

local function m4Start()
    if m4On then return end
    Tracker.retain()
    if not m4Capture(lp.Character) then
        Tracker.release()
        error("no character", 0)
    end
    m4On = true

    -- Unwind fully if either binding fails, so a throw here can never
    -- strand the method half-running with the button reading OFF.
    local ok, err = pcall(function()
        m4Heart = RunService.Heartbeat:Connect(m4Down)
        RunService:BindToRenderStep("InvisM4", Enum.RenderPriority.Last.Value + 1, m4Up)
        m4Render = true
    end)
    if not ok then
        m4On = false
        if m4Heart then m4Heart:Disconnect(); m4Heart = nil end
        if m4Render then
            pcall(function() RunService:UnbindFromRenderStep("InvisM4") end)
            m4Render = nil
        end
        m4Restore()
        Tracker.release()
        error(err, 0)
    end
end

local function m4Stop()
    if not m4On then return end
    m4On = false

    if m4Heart then m4Heart:Disconnect() end
    m4Heart = nil
    if m4Render then
        pcall(function() RunService:UnbindFromRenderStep("InvisM4") end)
        m4Render = nil
    end

    m4Restore()
    Tracker.release()
end

--=====================================================================
-- Wiring
--=====================================================================

table.insert(Tracker.onAdd,  m1OnAdd)
table.insert(Tracker.onAdd,  m4OnAdd)
table.insert(Tracker.onChar, m1OnChar)
table.insert(Tracker.onChar, m4OnChar)

local function bind(btn, paint, start, stop, guard)
    local on = false
    btn.MouseButton1Click:Connect(function()
        if not on and guard then
            local msg = guard()
            if msg then status.Text = msg; return end
        end
        on = not on
        local ok, err = pcall(on and start or stop)
        if not ok then
            warn("[Invis]", err)
            status.Text = tostring(err):sub(1, 34)
            on = not on
            return
        end
        paint(on)
    end)
end

bind(btn1, paint1, m1Start, m1Stop)
bind(btn2, paint2, m2Start, m2Stop)
bind(btn3, paint3, m3Start, m3Stop, function()
    if not sethiddenproperty then return "M3 unsupported: no sethiddenproperty" end
end)
bind(btn4, paint4, m4Start, m4Stop, function()
    if not lp.Character then return "M4: no character" end
end)

local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if m3On and m3Resync > 0 then
        status.Text = "RESYNC"
        return
    end

    statusClock += dt
    if statusClock < 0.1 then return end
    statusClock = 0

    if m4On then
        status.Text = string.format("under map %dst  ·  hitbox up", CONFIG.UNDER_DEPTH)
    elseif m3On then
        status.Text = string.format("drift %.1f studs  ·  [%s] resync",
            m3Drift, CONFIG.RESYNC_KEY.Name)
    elseif m1On or m2On then
        local n = 0
        for _ in pairs(Tracker.parts) do n += 1 end
        status.Text = string.format("tracking %d parts", n)
    else
        status.Text = "idle"
    end
end)

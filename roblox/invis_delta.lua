--=====================================================================
-- roblox/invis_delta.lua
-- Delta executor — three independent invisibility methods, GUI toggles.
--
--   1. LTM Loop      render-step LocalTransparencyModifier enforcement
--   2. Meta Hook     __index / __newindex intercept (resets die, checks lie)
--   3. Net Desync    simulation-radius ownership drop + burst resync
--
-- HumanoidRootPart is never hidden, moved, or unparented by methods 1-2,
-- so the server-side hitbox and tool attacks stay valid.
--=====================================================================

local CONFIG = {
    GUI_NAME      = "InvisGUI",
    RESYNC_KEY    = Enum.KeyCode.R,   -- M3: burst-resync so a swing lands where you stand
    RESYNC_FRAMES = 6,                -- how many frames ownership is handed back
    EFFECT_PERIOD = 0.5,              -- seconds between effect re-assert passes
    HIDE_NAMETAG  = true,             -- M1 also kills the humanoid name/health display
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer

-- ── executor env (undefined globals resolve to nil, never throw) ──────────────

local gethui            = gethui
local hookmetamethod    = hookmetamethod
local getrawmetatable   = getrawmetatable
local setreadonly       = setreadonly
local sethiddenproperty = sethiddenproperty
local newcclosure       = newcclosure or function(f) return f end
local checkcaller       = checkcaller or function() return false end

local function hookmm(name, fn)
    if hookmetamethod then
        return hookmetamethod(game, name, newcclosure(fn))
    end
    local mt  = getrawmetatable(game)
    local old = mt[name]
    setreadonly(mt, false)
    mt[name] = newcclosure(fn)
    setreadonly(mt, true)
    return old
end

local function unhookmm(name, old)
    if not old then return end
    if hookmetamethod then
        hookmetamethod(game, name, old)
        return
    end
    local mt = getrawmetatable(game)
    setreadonly(mt, false)
    mt[name] = old
    setreadonly(mt, true)
end

--=====================================================================
-- Tracker — one live set of "my visible instances", shared by M1 and M2.
-- Replaces the per-frame GetDescendants() scan: parts are ingested once
-- on spawn and incrementally as they replicate in.
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
    char    = nil,
    hum     = nil,
    onAdd   = {},   -- array of fn(inst, kind)
    onChar  = {},   -- array of fn(char)
    _conns  = {},
    _users  = 0,
}

local function classify(inst)
    if inst:IsA("BasePart") then
        return inst.Name ~= "HumanoidRootPart" and "part" or nil
    end
    return EFFECT_PROP[inst.ClassName] and "effect" or nil
end

function Tracker._ingest(inst)
    local kind = classify(inst)
    if not kind then return end
    if kind == "part" then
        Tracker.parts[inst] = true
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
    table.clear(Tracker.parts)
    table.clear(Tracker.effects)

    for _, d in ipairs(char:GetDescendants()) do
        Tracker._ingest(d)
    end

    table.insert(Tracker._conns, char.DescendantAdded:Connect(Tracker._ingest))
    table.insert(Tracker._conns, char.DescendantRemoving:Connect(function(inst)
        Tracker.parts[inst]   = nil
        Tracker.effects[inst] = nil
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
    Tracker.char, Tracker.hum = nil, nil
end

--=====================================================================
-- GUI
--=====================================================================

local old = (gethui and gethui() or game:GetService("CoreGui")):FindFirstChild(CONFIG.GUI_NAME)
if old then old:Destroy() end

local sg = Instance.new("ScreenGui")
sg.Name            = CONFIG.GUI_NAME
sg.ResetOnSpawn    = false
sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
sg.Parent          = (gethui and gethui()) or game:GetService("CoreGui")

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 250, 0, 166)
frame.Position         = UDim2.new(0, 12, 0.5, -83)
frame.BackgroundColor3  = Color3.fromRGB(16, 16, 18)
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

local btn1, paint1 = makeBtn("LTM Loop",   30,  Color3.fromRGB(0, 132, 62))
local btn2, paint2 = makeBtn("Meta Hook",  66,  Color3.fromRGB(0, 92, 178))
local btn3, paint3 = makeBtn("Net Desync", 102, Color3.fromRGB(150, 74, 0))

local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -20, 0, 20)
status.Position               = UDim2.new(0, 10, 0, 138)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = Color3.fromRGB(118, 118, 126)
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Font                   = Enum.Font.Code
status.TextSize               = 11
status.Parent                 = frame

--=====================================================================
-- Method 1 — LocalTransparencyModifier enforcement
--
-- Runs at RenderPriority.Last+1: LTM is a render-frame property, so the
-- write has to land after the renderer and the Humanoid have had their
-- pass, otherwise a camera/state change silently clears it.
-- Writes are gated on a value check, so a steady frame costs one compare
-- per part instead of one property write per part.
--=====================================================================

local m1On, m1Orig, m1EffectClock = false, {}, 0

local function m1HideEffect(inst)
    local prop = Tracker.effects[inst]
    if not prop then return end
    if m1Orig[inst] == nil then m1Orig[inst] = inst[prop] end
    local want = (prop == "Transparency") and 1 or false
    if inst[prop] ~= want then inst[prop] = want end
end

local function m1HideNametag()
    local hum = Tracker.hum
    if not (CONFIG.HIDE_NAMETAG and hum) then return end
    if m1Orig[hum] == nil then
        m1Orig[hum] = {
            hum.DisplayDistanceType, hum.NameDisplayDistance, hum.HealthDisplayDistance,
        }
    end
    hum.DisplayDistanceType    = Enum.HumanoidDisplayDistanceType.None
    hum.NameDisplayDistance    = 0
    hum.HealthDisplayDistance  = 0
end

local function m1OnAdd(inst, kind)
    if not m1On then return end
    if kind == "part" then
        inst.LocalTransparencyModifier = 1
    else
        m1HideEffect(inst)
    end
end

local function m1OnChar()
    if not m1On then return end
    m1HideNametag()
end

local function m1Step(dt)
    for part in pairs(Tracker.parts) do
        if part.LocalTransparencyModifier ~= 1 then
            part.LocalTransparencyModifier = 1
        end
    end

    m1EffectClock += dt
    if m1EffectClock >= CONFIG.EFFECT_PERIOD then
        m1EffectClock = 0
        for inst in pairs(Tracker.effects) do m1HideEffect(inst) end
        m1HideNametag()
    end
end

local function m1Start()
    m1On = true
    Tracker.retain()
    for part in pairs(Tracker.parts) do part.LocalTransparencyModifier = 1 end
    for inst in pairs(Tracker.effects) do m1HideEffect(inst) end
    m1HideNametag()
    RunService:BindToRenderStep("InvisM1", Enum.RenderPriority.Last.Value + 1, m1Step)
end

local function m1Stop()
    m1On = false
    pcall(function() RunService:UnbindFromRenderStep("InvisM1") end)

    for part in pairs(Tracker.parts) do
        part.LocalTransparencyModifier = 0
    end
    for inst, saved in pairs(m1Orig) do
        if inst.Parent then
            if typeof(saved) == "table" then
                inst.DisplayDistanceType   = saved[1]
                inst.NameDisplayDistance   = saved[2]
                inst.HealthDisplayDistance = saved[3]
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
-- Method 2 — metatable intercept
--
-- __newindex is what makes this survive resets: a game script's write to
-- LocalTransparencyModifier / Transparency on one of our parts is
-- swallowed outright, so a reset loop can't put the limb back. The value
-- it tried to write is remembered.
--
-- __index then hands that remembered value back, so a script reading the
-- property sees exactly what it believes it set — the character reads as
-- fully normal to anything that checks, while the real render value stays
-- pinned at 1. Our own reads (checkcaller) pass straight through.
--
-- __index fires for every property read in the entire game, so the guard
-- order matters: interned-string compare first, then a raw table lookup.
-- No Instance access happens inside either hook, so it cannot recurse.
--=====================================================================

local SPOOF_PROP = { LocalTransparencyModifier = true, Transparency = true }

local m2On, m2Spoof = false, {}
local m2OldIndex, m2OldNewIndex

local function m2OnAdd(inst, kind)
    if m2On and kind == "part" and m2OldNewIndex then
        m2OldNewIndex(inst, "LocalTransparencyModifier", 1)
    end
end

local function m2Start()
    if m2On then return end
    m2On = true
    Tracker.retain()

    m2OldIndex = hookmm("__index", function(self, key)
        if SPOOF_PROP[key] and not checkcaller() and Tracker.parts[self] then
            local v = m2Spoof[self]
            if v ~= nil then return v end
            return 0
        end
        return m2OldIndex(self, key)
    end)

    m2OldNewIndex = hookmm("__newindex", function(self, key, val)
        if SPOOF_PROP[key] and not checkcaller() and Tracker.parts[self] then
            m2Spoof[self] = val   -- let it think the write landed
            return
        end
        return m2OldNewIndex(self, key, val)
    end)

    -- Apply through the captured original so our own __newindex can't eat it.
    for part in pairs(Tracker.parts) do
        m2OldNewIndex(part, "LocalTransparencyModifier", 1)
    end
end

local function m2Stop()
    if not m2On then return end
    m2On = false

    for part in pairs(Tracker.parts) do
        if part.Parent and m2OldNewIndex then
            m2OldNewIndex(part, "LocalTransparencyModifier", 0)
        end
    end

    unhookmm("__newindex", m2OldNewIndex)
    unhookmm("__index",    m2OldIndex)
    m2OldIndex, m2OldNewIndex = nil, nil
    table.clear(m2Spoof)
    Tracker.release()
end

--=====================================================================
-- Method 3 — network ownership desync
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
-- Wiring
--=====================================================================

table.insert(Tracker.onAdd,  m1OnAdd)
table.insert(Tracker.onAdd,  m2OnAdd)
table.insert(Tracker.onChar, m1OnChar)

do
    local on = false
    btn1.MouseButton1Click:Connect(function()
        on = not on
        local ok, err = pcall(on and m1Start or m1Stop)
        if not ok then warn("[Invis] M1:", err); on = not on; return end
        paint1(on)
    end)
end

do
    local on = false
    btn2.MouseButton1Click:Connect(function()
        if not (hookmetamethod or (getrawmetatable and setreadonly)) then
            status.Text = "M2 unsupported: no metatable API"
            return
        end
        on = not on
        local ok, err = pcall(on and m2Start or m2Stop)
        if not ok then warn("[Invis] M2:", err); on = not on; return end
        paint2(on)
    end)
end

do
    local on = false
    btn3.MouseButton1Click:Connect(function()
        if not sethiddenproperty then
            status.Text = "M3 unsupported: no sethiddenproperty"
            return
        end
        on = not on
        local ok, err = pcall(on and m3Start or m3Stop)
        if not ok then warn("[Invis] M3:", err); on = not on; return end
        paint3(on)
    end)
end

local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if m3On and m3Resync > 0 then
        status.Text = "RESYNC"
        return
    end

    statusClock += dt
    if statusClock < 0.1 then return end
    statusClock = 0

    if m3On then
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

--=====================================================================
-- roblox/invis_delta.lua
-- Delta executor — invisibility methods, GUI toggles.
--
--   1. Transparency  direct Transparency + LTM writes          [LOCAL ONLY]
--   2. Sim Radius    legacy SimulationRadius ownership drop    [likely dead]
--   3. Net Desync    root parked at a fixed anchor             [root channel]
--   4. Under Map     root parked below you, tracking           [root channel]
--
-- WHAT A CLIENT CAN ACTUALLY PUSH TO THE SERVER
--
-- Live testing settled this. An earlier build disabled every Motor6D and
-- CFramed the limbs underground; the reported result was "freezes my
-- animation but just for me, others still see my normal animation". That
-- single observation proves the chain: the joint writes landed locally,
-- did NOT replicate, so the server's rig stayed intact and rebuilt the
-- pose for everyone else from the animation stream.
--
-- So: structural and pose state does not replicate from a client. Not
-- Motor6D.Enabled, not Motor6D.Transform, not limb CFrames, and not
-- Transparency (that one never could — property changes replicate
-- server->client only). The ONLY character state a client pushes is the
-- root assembly's CFrame, plus Humanoid state and which animations play.
--
-- Everything that hides you from other players therefore has to move the
-- ROOT. M3 and M4 do exactly that, via the frame order:
--
--     RenderStepped -> render -> Stepped -> physics -> Heartbeat -> replicate
--
--     Heartbeat      -> write the fake root position   (sampled, replicated)
--     RenderStepped  -> write the true root position   (physics + camera)
--
-- Physics always runs from the true position, so movement, animation and
-- collision behave normally; only the sampled value is a lie. Nothing is
-- structurally modified, so no frozen animation.
--
-- The Heartbeat write is still a physical move, though: for M4 it shoves
-- the HRP into terrain, and the physics step before the next RenderStepped
-- generates a real collision-response velocity. Restoring only the CFrame
-- there left that velocity live, and it bled downward frame over frame
-- until fall damage or FallenPartsDestroyHeight killed the character —
-- confirmed by an alt-account observer watching it happen. parkUp now
-- restores the pre-write velocity alongside the CFrame, not just position.
--
-- THE TRADE YOU CANNOT ENGINEER AROUND
--
-- If the server believes you are elsewhere, server-validated hits resolve
-- from elsewhere. Being hidden server-side and landing server-validated
-- melee at your real position are the same variable pulled two ways.
-- RESYNC_KEY is the escape hatch: it stops the lie for a few frames so
-- your true position replicates and the blow registers. Games that do
-- client-authoritative damage (fire a remote naming the target) are
-- unaffected — hits land wherever the server thinks you are.
--
-- Confirm with a second client. Everything below that concerns other
-- players is unverified from this side.
--=====================================================================

local CONFIG = {
    GUI_NAME      = "InvisGUI",
    RESYNC_KEY    = Enum.KeyCode.R,   -- hold your true position for a few frames
    RESYNC_FRAMES = 6,                -- how many frames the lie is suspended
    EFFECT_PERIOD = 0.5,              -- seconds between effect re-assert passes
    HIDE_NAMETAG  = true,             -- M1 also kills the humanoid name/health display
    UNDER_DEPTH   = 32,               -- M4: studs below you the root is parked
    DESTROY_CLEAR = 32,               -- M4: min studs to stay above FallenPartsDestroyHeight
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer

-- ── executor env (undefined globals resolve to nil, never throw) ──────────────

local gethui            = gethui
local sethiddenproperty = sethiddenproperty

--=====================================================================
-- Tracker — one live set of "my visible instances".
--=====================================================================

local EFFECT_PROP = {
    Decal = "Transparency", Texture = "Transparency",
    ParticleEmitter = "Enabled", Trail = "Enabled", Beam = "Enabled",
    Smoke = "Enabled", Fire = "Enabled", Sparkles = "Enabled",
    BillboardGui = "Enabled", SurfaceGui = "Enabled",
}

local Tracker = {
    parts   = {},   -- [BasePart] = true   (non-HRP)
    effects = {},   -- [Instance] = propertyName
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
    Tracker.hrp  = char:FindFirstChild("HumanoidRootPart")
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
    Tracker.char, Tracker.hum, Tracker.hrp = nil, nil, nil
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
local btn2, paint2 = makeBtn("Sim Radius  (legacy)", 66,  Color3.fromRGB(88, 88, 96))
local btn3, paint3 = makeBtn("Net Desync",           102, Color3.fromRGB(150, 74, 0))
local btn4, paint4 = makeBtn("Under Map",            138, Color3.fromRGB(132, 0, 78))

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
-- Both properties are client render state, and Roblox replicates
-- property changes server->client only, so nothing here reaches another
-- player. This hides your body from your own camera and nothing else.
-- Kept because it is genuinely useful for that, and because it leaves
-- the rig completely intact.
--
-- Do not run this together with M4: it hides the body M4 exists to let
-- you keep seeing.
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
    if kind == "part" then m1HidePart(inst) else m1HideEffect(inst) end
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
-- Method 2 — SimulationRadius drop                        [LEGACY]
--
-- The classic desync: drop the client's simulation radius to 0 so it
-- stops claiming physics ownership of its own character and stops
-- pushing root updates, leaving the server on a stale copy.
--
-- Roblox moved network ownership to a server-side decision years ago and
-- stopped honouring client writes to these hidden properties, so this is
-- expected to do nothing in a current game. It is kept as its own toggle
-- rather than bundled into M3 so you can establish, with a second
-- client, whether it still does anything here — it costs nothing to
-- leave off, and M3/M4 do not depend on it.
--=====================================================================

local m2On, m2Conn = false, nil

local function m2Radius(v)
    if not sethiddenproperty then return end
    pcall(sethiddenproperty, lp, "SimulationRadius", v)
    pcall(sethiddenproperty, lp, "MaximumSimulationRadius", v)
end

local function m2Start()
    m2On  = true
    -- Re-asserted every frame: the server re-grants ownership on its own
    -- cadence, so a single write would be undone.
    m2Conn = RunService.Heartbeat:Connect(function() m2Radius(0) end)
end

local function m2Stop()
    m2On = false
    if m2Conn then m2Conn:Disconnect() end
    m2Conn = nil
    m2Radius(math.huge)
end

--=====================================================================
-- Park — the shared root-lie core behind M3 and M4.
--
-- Heartbeat is the last hook before the replication snapshot, so the
-- value written there is what leaves the machine. RenderStepped runs
-- before the next physics step, so restoring the true position there
-- means the simulation never sees the lie: walking, jumping, collision
-- and animation all behave normally.
--
-- The true position is captured at Heartbeat (post-physics) rather than
-- at RenderStepped, because by RenderStepped the root already holds the
-- fake value written the frame before.
--
-- Modes:
--   "anchor"  park at a fixed point       — you appear to stand still
--   "under"   park UNDER_DEPTH below you  — you appear to be underground,
--             tracking horizontally so the server sees ordinary movement
--             and a resync is only a short vertical hop
--=====================================================================

local Park = {
    on      = false,
    mode    = nil,   -- "anchor" | "under"
    fixed   = nil,   -- CFrame, anchor mode
    real    = nil,   -- last true root CFrame
    realVel = nil,   -- last true AssemblyLinearVelocity
    realAng = nil,   -- last true AssemblyAngularVelocity
    hold    = 0,     -- frames the lie is suspended
    off     = 0,     -- last applied offset magnitude, for the readout
    heart   = nil,
    bound   = false,
}

local function parkTarget(realCF)
    if Park.mode == "under" then
        -- Below FallenPartsDestroyHeight the engine deletes parts, and a
        -- deleted limb is a dead character. Stay clear of that plane
        -- while still sitting below the root.
        local rootY   = realCF.Position.Y
        local floorY  = workspace.FallenPartsDestroyHeight + CONFIG.DESTROY_CLEAR
        local y = math.min(math.max(rootY - CONFIG.UNDER_DEPTH, floorY), rootY - 4)
        return CFrame.new(realCF.Position.X, y, realCF.Position.Z)
    end
    return Park.fixed
end

local function parkDown()
    local hrp = Tracker.hrp
    if not (hrp and hrp.Parent) then return end

    Park.real    = hrp.CFrame                   -- true, post-physics
    Park.realVel = hrp.AssemblyLinearVelocity
    Park.realAng = hrp.AssemblyAngularVelocity

    if Park.hold > 0 then
        Park.hold -= 1
        Park.off  = 0
        if Park.hold == 0 and Park.mode == "anchor" then
            Park.fixed = hrp.CFrame -- re-anchor wherever we surfaced
        end
        return                      -- let the true position replicate
    end

    local target = parkTarget(Park.real)
    if not target then return end
    hrp.CFrame = target
    Park.off   = (target.Position - Park.real.Position).Magnitude
end

local function parkUp()
    if Park.hold > 0 then return end
    local hrp = Tracker.hrp
    if not (hrp and hrp.Parent and Park.real) then return end
    hrp.CFrame = Park.real
    -- Restore velocity too, not just position. The Heartbeat write can
    -- shove the HRP into terrain (M4 parks it underground); the physics
    -- step in between generates a collision-response velocity that
    -- would otherwise survive the CFrame restore and bleed downward
    -- frame over frame until fall damage or FallenPartsDestroyHeight
    -- kills you. Restoring the true post-physics velocity here, not
    -- zero, keeps legitimate movement (walking, jumping) unaffected.
    if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
    if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
end

local function parkOnChar()
    Park.real, Park.realVel, Park.realAng = nil, nil, nil
    if Park.mode == "anchor" then
        local hrp = Tracker.hrp
        Park.fixed = hrp and hrp.CFrame or nil
    end
end

local function parkStart(mode)
    if Park.on then return end
    Tracker.retain()

    local hrp = Tracker.hrp
    if not hrp then
        Tracker.release()
        error("no character", 0)
    end

    Park.mode    = mode
    Park.fixed   = hrp.CFrame
    Park.real    = hrp.CFrame
    Park.realVel = hrp.AssemblyLinearVelocity
    Park.realAng = hrp.AssemblyAngularVelocity
    Park.hold    = 0
    Park.off     = 0
    Park.on      = true

    -- Unwind fully if either binding throws, so a failure cannot strand
    -- the lie running with its button reading OFF.
    local ok, err = pcall(function()
        Park.heart = RunService.Heartbeat:Connect(parkDown)
        RunService:BindToRenderStep("InvisPark", Enum.RenderPriority.Last.Value + 1, parkUp)
        Park.bound = true
    end)
    if not ok then
        Park.on = false
        if Park.heart then Park.heart:Disconnect(); Park.heart = nil end
        if Park.bound then
            pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
            Park.bound = false
        end
        Tracker.release()
        error(err, 0)
    end
end

local function parkStop()
    if not Park.on then return end
    Park.on = false

    if Park.heart then Park.heart:Disconnect() end
    Park.heart = nil
    if Park.bound then
        pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
        Park.bound = false
    end

    -- Leave the root where the player actually is, not on the lie, and
    -- with its real velocity, not whatever the last underground
    -- collision left it holding.
    local hrp = Tracker.hrp
    if hrp and hrp.Parent and Park.real then
        hrp.CFrame = Park.real
        if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
        if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
    end

    Park.mode, Park.fixed, Park.real = nil, nil, nil
    Park.realVel, Park.realAng = nil, nil
    Park.hold, Park.off = 0, 0
    Tracker.release()
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe or not Park.on then return end
    if input.KeyCode == CONFIG.RESYNC_KEY then
        Park.hold = CONFIG.RESYNC_FRAMES
    end
end)

--=====================================================================
-- Methods 3 and 4 — the two Park modes.
--
-- M3 leaves your body standing where you switched it on; walk away and
-- the server still has you at the anchor.
--
-- M4 keeps the lie directly beneath you. Other players see nothing
-- because you are genuinely underground server-side, while your own
-- screen, physics and animation stay at the surface.
--
-- Under either one, tap RESYNC_KEY to suspend the lie for a few frames
-- so a server-validated hit resolves from your real position.
--=====================================================================

local m3On, m4On = false, false

local function m3Start() parkStart("anchor"); m3On = true end
local function m3Stop()  m3On = false; parkStop() end
local function m4Start() parkStart("under");  m4On = true end
local function m4Stop()  m4On = false; parkStop() end

--=====================================================================
-- Wiring
--=====================================================================

table.insert(Tracker.onAdd,  m1OnAdd)
table.insert(Tracker.onChar, m1OnChar)
table.insert(Tracker.onChar, parkOnChar)

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
bind(btn2, paint2, m2Start, m2Stop, function()
    if not sethiddenproperty then return "no sethiddenproperty" end
end)
bind(btn3, paint3, m3Start, m3Stop, function()
    if m4On then return "turn Under Map off first" end
    if not lp.Character then return "no character" end
end)
bind(btn4, paint4, m4Start, m4Stop, function()
    if m3On then return "turn Net Desync off first" end
    if not lp.Character then return "no character" end
end)

-- The readout reports the offset we WRITE, not a claim that the server
-- accepted it. A previous build showed a drift figure derived purely
-- from local position, which climbed whenever you walked and so looked
-- like proof of a desync that was not happening. Only a second client
-- can confirm any of this.
local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if Park.on and Park.hold > 0 then
        status.Text = "RESYNC — true position sent"
        return
    end

    statusClock += dt
    if statusClock < 0.1 then return end
    statusClock = 0

    local bits = {}
    if m1On then bits[#bits + 1] = "self" end
    if m2On then bits[#bits + 1] = "simrad" end
    if Park.on then
        bits[#bits + 1] = string.format("%s sent %.0fst off  [%s]",
            Park.mode, Park.off, CONFIG.RESYNC_KEY.Name)
    end

    status.Text = (#bits > 0) and table.concat(bits, "  ·  ") or "idle"
end)

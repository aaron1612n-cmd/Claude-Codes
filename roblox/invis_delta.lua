--=====================================================================
-- roblox/invis_delta.lua
-- Delta executor — root-parking desync, GUI toggles.
--
--   1. Net Desync   root parked at a fixed anchor       [root channel]
--   2. Under Map    root parked below you, tracking     [root channel]
--
-- WHAT A CLIENT CAN ACTUALLY PUSH TO THE SERVER
--
-- Settled by live testing. The only character state a client pushes is the
-- root assembly's CFrame, plus Humanoid state and which animations play.
-- Structural and pose state does not replicate from a client: not
-- Motor6D.Enabled, not Motor6D.Transform, not limb CFrames, and not
-- Transparency (property changes replicate server->client only). An
-- earlier build disabled every Motor6D and CFramed the limbs underground;
-- it froze the animation locally while everyone else saw normal movement,
-- which proves the joint writes never left the machine.
--
-- Net Desync has since been confirmed working against a second client, so
-- the root channel does replicate and this approach is sound. Transparency
-- and SimulationRadius toggles were removed: the first is self-cloak only
-- by design, the second has been inert since Roblox moved network
-- ownership server-side.
--
-- FRAME ORDER — WHERE EACH WRITE GOES AND WHY
--
--     RenderStepped -> render -> Stepped -> physics -> Heartbeat -> replicate
--
--     RenderStepped (priority First, 0) -> restore TRUE position
--     Stepped       (pre-physics)       -> restore TRUE position
--     Heartbeat     (pre-snapshot)      -> capture truth, write the LIE
--
-- The root holds the lie only between Heartbeat and the next frame's first
-- restore, which is exactly the replication window. Three details, each one
-- a bug that was live in an earlier build:
--
-- 1. The restore MUST run before RenderPriority.Camera (200). The default
--    camera script samples the root at 200; a restore bound at Last+1
--    (2001) runs after it, so the camera reads the lie and locks itself at
--    the anchor or underground. First (0) beats it.
--
-- 2. The Stepped restore is not redundant with the RenderStepped one. Drop
--    a render frame — streaming, load hitch, anything that happens the
--    moment you start moving — and only Heartbeat runs, so the capture
--    adopts the LIE as truth and the next lie is parked relative to it.
--    That ratchets you downward a step per dropped frame until the void
--    takes you. Stepped fires with the physics step regardless of
--    rendering, so physics always starts from truth; RESTORE_EPSILON
--    rejects a sample that is still sitting on the last lie as a backstop.
--
-- 3. Roblox ships a root update only when the CFrame actually CHANGES.
--    Writing an identical value every frame produces no delta and no
--    packet, so a player standing perfectly still replicates nothing and
--    the server holds the stale parked position — the resync appears to do
--    nothing until you walk. The hold window alternates a sub-stud nudge so
--    every frame of it is a genuine delta.
--
-- THE TRADE YOU CANNOT ENGINEER AROUND
--
-- If the server believes you are elsewhere, server-validated hits resolve
-- from elsewhere. Being hidden server-side and landing server-validated
-- melee at your real position are the same variable pulled two ways.
-- RESYNC_KEY is the escape hatch: hold it to suspend the lie so your true
-- position replicates and the blow registers, release to go back under.
-- Games that do client-authoritative damage (fire a remote naming the
-- target) are unaffected — hits land wherever the server thinks you are.
--=====================================================================

local CONFIG = {
    GUI_NAME        = "InvisGUI",
    RESYNC_KEY      = Enum.KeyCode.R,  -- hold to send your true position
    RESYNC_FRAMES   = 15,              -- tail frames after release (~0.25s @60)
    RESYNC_JITTER   = 0.02,            -- studs, alternating, to force a delta
    UNDER_DEPTH     = 32,              -- studs below you the root is parked
    DESTROY_CLEAR   = 32,              -- min studs above FallenPartsDestroyHeight
    RESTORE_EPSILON = 0.5,             -- studs; nearer the last lie than this
                                       -- means the restore never ran
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer

-- executor env (undefined globals resolve to nil, never throw)
local gethui = gethui

--=====================================================================
-- Character — the live root reference, rebound on respawn.
--=====================================================================

local Char = {
    model  = nil,
    hum    = nil,
    hrp    = nil,
    onChar = {},   -- array of fn(model)
}

function Char.bind(model)
    Char.model = model
    Char.hum   = model:FindFirstChildOfClass("Humanoid")
    Char.hrp   = model:FindFirstChild("HumanoidRootPart")
    for _, fn in ipairs(Char.onChar) do
        local ok, err = pcall(fn, model)
        if not ok then warn("[Invis] onChar:", err) end
    end
end

function Char.start()
    if lp.Character then Char.bind(lp.Character) end
    lp.CharacterAdded:Connect(function(model)
        model:WaitForChild("HumanoidRootPart", 10)
        task.wait()
        Char.bind(model)
    end)
end

-- A dead or half-built character is never worth writing to: the root may be
-- gone, and Humanoid death ragdolls the assembly out from under us.
local function alive()
    local hrp, hum = Char.hrp, Char.hum
    if not (hrp and hrp.Parent) then return false, nil end
    if not (hum and hum.Health > 0) then return false, nil end
    return true, hrp
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
frame.Size             = UDim2.new(0, 250, 0, 134)
frame.Position         = UDim2.new(0, 12, 0.5, -67)
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

local btnDesync, paintDesync = makeBtn("Net Desync", 30, Color3.fromRGB(150, 74, 0))
local btnUnder,  paintUnder  = makeBtn("Under Map",  66, Color3.fromRGB(132, 0, 78))

local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -20, 0, 20)
status.Position               = UDim2.new(0, 10, 0, 106)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = Color3.fromRGB(118, 118, 126)
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Font                   = Enum.Font.Code
status.TextSize               = 11
status.Parent                 = frame

--=====================================================================
-- Park — the shared root-lie core behind both methods.
--
-- Modes:
--   "anchor"  park at a fixed point       — you appear to stand still
--   "under"   park UNDER_DEPTH below you  — you appear to be underground,
--             tracking horizontally so the server sees ordinary movement
--             and a resync is only a short vertical hop
--=====================================================================

local Park = {
    on       = false,
    mode     = nil,   -- "anchor" | "under"
    fixed    = nil,   -- CFrame, anchor mode
    real     = nil,   -- last known TRUE root CFrame
    realVel  = nil,   -- last known true AssemblyLinearVelocity
    realAng  = nil,   -- last known true AssemblyAngularVelocity
    lastFake = nil,   -- CFrame written at the previous Heartbeat, or nil
    holdKey  = false, -- RESYNC_KEY currently held
    hold     = 0,     -- tail frames after release
    jitter   = CONFIG.RESYNC_JITTER,
    off      = 0,     -- last offset WRITTEN, for the readout
    heart    = nil,
    step     = nil,
    bound    = false,
}

local function parkTarget(realCF)
    if Park.mode == "under" then
        -- Below FallenPartsDestroyHeight the engine deletes parts, and a
        -- deleted root is a dead character. Stay clear of that plane while
        -- still sitting below yourself.
        local rootY  = realCF.Position.Y
        local floorY = workspace.FallenPartsDestroyHeight + CONFIG.DESTROY_CLEAR
        local y = math.min(math.max(rootY - CONFIG.UNDER_DEPTH, floorY), rootY - 4)
        return CFrame.new(realCF.Position.X, y, realCF.Position.Z)
    end
    return Park.fixed
end

-- Put the root back where the player actually is. Bound to BOTH
-- RenderStepped (before the camera samples it) and Stepped (before physics
-- runs), so neither the view nor the simulation ever sees the lie.
local function parkRestore()
    local hrp = Char.hrp
    if not (Park.on and hrp and hrp.Parent and Park.real) then return end
    hrp.CFrame = Park.real
    if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
    if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
end

local function parkDown()
    local ok, hrp = alive()
    if not ok then return end

    -- Adopt the post-physics root as truth only if a restore actually ran
    -- this frame. If both restores were skipped the root is still sitting on
    -- last frame's lie, and adopting it would park the next lie relative to
    -- the lie — a downward ratchet, one step per dropped frame, ending in
    -- the void. Reject that sample and keep the last known truth.
    local captured = hrp.CFrame
    local stale = Park.lastFake ~= nil
        and (captured.Position - Park.lastFake.Position).Magnitude < CONFIG.RESTORE_EPSILON
    if not stale then
        Park.real    = captured
        Park.realVel = hrp.AssemblyLinearVelocity
        Park.realAng = hrp.AssemblyAngularVelocity
    end
    if not Park.real then return end

    if Park.holdKey or Park.hold > 0 then
        if not Park.holdKey then Park.hold -= 1 end
        Park.off      = 0
        Park.lastFake = nil
        if Park.hold == 0 and not Park.holdKey and Park.mode == "anchor" then
            Park.fixed = Park.real   -- re-anchor wherever we surfaced
        end
        -- An unchanged CFrame produces no replication delta, so holding still
        -- during a resync would send nothing at all and leave the server on
        -- the stale park. Alternate a sub-stud nudge to guarantee a packet.
        Park.jitter = -Park.jitter
        hrp.CFrame  = Park.real + Vector3.new(0, Park.jitter, 0)
        return
    end

    local target = parkTarget(Park.real)
    if not target then return end
    hrp.CFrame    = target
    Park.lastFake = target
    Park.off      = (target.Position - Park.real.Position).Magnitude
end

local function parkOnChar()
    Park.real, Park.realVel, Park.realAng = nil, nil, nil
    Park.lastFake = nil
    if Park.mode == "anchor" then
        Park.fixed = Char.hrp and Char.hrp.CFrame or nil
    end
end

local function parkStart(mode)
    if Park.on then return end

    local ok, hrp = alive()
    if not ok then error("no character", 0) end

    Park.mode     = mode
    Park.fixed    = hrp.CFrame
    Park.real     = hrp.CFrame
    Park.realVel  = hrp.AssemblyLinearVelocity
    Park.realAng  = hrp.AssemblyAngularVelocity
    Park.lastFake = nil
    Park.hold     = 0
    Park.off      = 0
    Park.on       = true

    -- Unwind fully if any binding throws, so a failure cannot strand the lie
    -- running with its button reading OFF.
    local bindOk, err = pcall(function()
        Park.heart = RunService.Heartbeat:Connect(parkDown)
        Park.step  = RunService.Stepped:Connect(parkRestore)
        -- First (0) beats RenderPriority.Camera (200): the camera must sample
        -- the true position, not the lie, or it locks itself at the anchor.
        RunService:BindToRenderStep("InvisPark", Enum.RenderPriority.First.Value, parkRestore)
        Park.bound = true
    end)
    if not bindOk then
        Park.on = false
        if Park.heart then Park.heart:Disconnect(); Park.heart = nil end
        if Park.step  then Park.step:Disconnect();  Park.step  = nil end
        if Park.bound then
            pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
            Park.bound = false
        end
        error(err, 0)
    end
end

local function parkStop()
    if not Park.on then return end
    Park.on = false

    if Park.heart then Park.heart:Disconnect() end
    if Park.step  then Park.step:Disconnect()  end
    Park.heart, Park.step = nil, nil
    if Park.bound then
        pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
        Park.bound = false
    end

    -- Leave the root where the player actually is, not on the lie, and with
    -- its real velocity rather than whatever the last write left it holding.
    local hrp = Char.hrp
    if hrp and hrp.Parent and Park.real then
        hrp.CFrame = Park.real
        if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
        if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
    end

    Park.mode, Park.fixed, Park.real = nil, nil, nil
    Park.realVel, Park.realAng, Park.lastFake = nil, nil, nil
    Park.holdKey, Park.hold, Park.off = false, 0, 0
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe or not Park.on then return end
    if input.KeyCode == CONFIG.RESYNC_KEY then Park.holdKey = true end
end)

UIS.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.RESYNC_KEY then return end
    Park.holdKey = false
    Park.hold    = CONFIG.RESYNC_FRAMES   -- tail, so a tap still lands
end)

--=====================================================================
-- The two modes.
--
-- Net Desync leaves your body standing where you switched it on; walk away
-- and the server still has you at the anchor.
--
-- Under Map keeps the lie directly beneath you. Other players see nothing
-- because you are genuinely underground server-side, while your own screen,
-- physics and animation stay at the surface.
--
-- Under either one, hold RESYNC_KEY to suspend the lie so a server-validated
-- hit resolves from your real position.
--=====================================================================

local desyncOn, underOn = false, false

local function desyncStart() parkStart("anchor"); desyncOn = true end
local function desyncStop()  desyncOn = false; parkStop() end
local function underStart()  parkStart("under");  underOn  = true end
local function underStop()   underOn  = false; parkStop() end

--=====================================================================
-- Wiring
--=====================================================================

table.insert(Char.onChar, parkOnChar)
Char.start()

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

bind(btnDesync, paintDesync, desyncStart, desyncStop, function()
    if underOn then return "turn Under Map off first" end
    if not lp.Character then return "no character" end
end)
bind(btnUnder, paintUnder, underStart, underStop, function()
    if desyncOn then return "turn Net Desync off first" end
    if not lp.Character then return "no character" end
end)

-- The readout reports the offset we WRITE, never a claim that the server
-- accepted it. An early build showed a drift figure derived purely from
-- local position, which climbed whenever he walked and made a dead desync
-- look alive for two rounds. Only a second client confirms anything here.
local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if not Park.on then
        status.Text = "idle"
        return
    end

    if Park.holdKey or Park.hold > 0 then
        status.Text = "RESYNC — true position sent"
        return
    end

    statusClock += dt
    if statusClock < 0.1 then return end
    statusClock = 0

    status.Text = string.format("%s sent %.0fst off  [hold %s]",
        Park.mode, Park.off, CONFIG.RESYNC_KEY.Name)
end)

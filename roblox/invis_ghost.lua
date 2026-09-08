--=====================================================================
-- roblox/invis_ghost.lua
-- Delta executor — inverted root parking. Supersedes invis_delta.lua.
--
--   1. Net Desync   root lives at a fixed anchor          [root channel]
--   2. Under Map    root lives below you, tracking        [root channel]
--
-- WHY THE PREVIOUS BUILD ONLY HALF-WORKED
--
-- invis_delta.lua held the true position for almost the whole frame and
-- wrote the lie in the gap between Heartbeat and the next RenderStepped.
-- That is a race, and it is a race that is phase-locked against you.
--
-- Roblox replicates physics at 20Hz while the client renders at 60. The
-- sender therefore samples roughly every third frame, at the SAME phase of
-- the frame each time, because rendering and networking ride the same
-- scheduler. The lie occupied a sliver of that frame. If the sampling phase
-- fell anywhere in the render block or the physics block it read the true
-- position on every sample, deterministically, forever — which is exactly
-- what a player standing still saw: nothing replicated at all. Start moving
-- and frame times jitter, the phase drifts, and the lie lands on some
-- fraction of samples instead of none. Partial delivery is also where the
-- gliding came from: the server's copy is dragged back and forth between
-- the truth and the lie, and receiving clients interpolate across that at
-- 60Hz. One mechanism, both symptoms.
--
-- No amount of tuning fixes a design that holds the lie 5% of the time and
-- hopes the sampler looks then.
--
-- WHAT THIS BUILD DOES INSTEAD
--
-- The root LIVES at the lie. It returns to the true position only for the
-- physics step, which is the one consumer that actually requires it.
--
--     PreSimulation  (Stepped)    -> write TRUTH, physics steps from it
--     [physics runs]
--     PostSimulation (Heartbeat)  -> capture new truth, write LIE
--     [render phase, idle, frame boundary — all held on the LIE]
--
-- Whatever phase the 20Hz sender samples at, it lands on the lie unless it
-- lands inside the physics step itself. Delivery goes from a coin flip to
-- very nearly total, and it no longer depends on the player moving.
--
-- Two things locally would break, and both get fixed properly rather than
-- traded away:
--
--   * The camera would orbit the lie. So it does not watch the root at all.
--     A client-only invisible part is pinned at the true position and made
--     CameraSubject, so the stock camera scripts run their own occlusion and
--     zoom against the correct point. No manual camera math, and no added
--     latency: that part is updated from the same post-physics capture the
--     camera would have read off the root anyway.
--
--   * Your own body would draw at the lie. LocalTransparencyModifier is
--     client-only — which is precisely why it failed as a cloak in an early
--     build, and precisely what makes it the right tool here. Own character
--     is hidden locally, rewritten every frame after the stock character
--     scripts have had their turn at it.
--
-- The Humanoid Freefall problem the previous build had to correct by hand is
-- gone for free: physics now runs with the root at the true position, so the
-- state machine never sees a fall and never refuses ground movement.
--
-- WHAT A CLIENT CAN ACTUALLY PUSH — settled by live testing, do not retry
--
--   Transparency / LocalTransparencyModifier  server->client only, self-cloak
--   Motor6D.Enabled = false + limb CFrames    froze animation locally only
--   Motor6D.Transform collapse                same channel, same evidence
--   SimulationRadius = 0                      inert since ownership moved
--                                             server-side
--   Anchored = true                           kills replication outright;
--                                             ownership only sends unanchored
--
-- The root assembly CFrame is the lever. Humanoid state and playing
-- animations are the only other things that leave the machine.
--
-- THE TRADE YOU CANNOT ENGINEER AROUND
--
-- If the server believes you are elsewhere, server-validated hits resolve
-- from elsewhere. Being hidden server-side and landing server-validated
-- melee at your real position are the same variable pulled two ways.
-- RESYNC_KEY is the escape hatch: hold it and the lie is simply not written,
-- so the root holds truth for the entire frame and every sample carries it —
-- a far stronger resync than the old build could manage. Games with
-- client-authoritative damage (a remote naming the target) are unaffected.
--=====================================================================

local CONFIG = {
    GUI_NAME       = "InvisGhostGUI",
    RESYNC_KEY     = Enum.KeyCode.R,   -- hold: suspend the lie entirely
    RESYNC_FRAMES  = 12,               -- tail frames after release
    JITTER         = 0.03,             -- studs, alternating, on every write
    UNDER_DEPTH    = 32,               -- studs below you the root is parked
    DESTROY_CLEAR  = 32,               -- min studs above FallenPartsDestroyHeight
    EYE_HEIGHT     = 1.5,              -- camera part offset above the root
    HIDE_SELF      = true,             -- hide own body locally (it draws at
                                       -- the lie, so leaving it visible shows
                                       -- your avatar underground)
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer
local clock      = os.clock

-- executor env (undefined globals resolve to nil, never throw)
local gethui = gethui

--=====================================================================
-- Character — live references, rebound on respawn.
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
        if not ok then warn("[Ghost] onChar:", err) end
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
-- View — the local side of the inversion.
--
-- The root spends the frame at the lie, so neither the camera nor the
-- renderer may read it. Eye is a client-created part (client instances do
-- not replicate) pinned at the true position and handed to the camera as its
-- subject; the stock camera scripts then do their own occlusion and zoom
-- against a point that is actually where the player is.
--=====================================================================

local View = {
    eye      = nil,
    prevSubj = nil,
    on       = false,
}

function View.ensureEye()
    if View.eye and View.eye.Parent then return View.eye end
    local p = Instance.new("Part")
    p.Name         = "GhostEye"
    p.Size         = Vector3.new(1, 1, 1)
    p.Transparency = 1
    p.Anchored     = true
    p.CanCollide   = false
    p.CanQuery     = false
    p.CanTouch     = false
    p.CastShadow   = false
    p.Massless     = true
    p.Parent       = workspace
    View.eye = p
    return p
end

-- Height of the camera point above the root. Read from the real rig where
-- possible so R6 and R15 both sit right, with the stock offset as fallback.
local function eyeHeight()
    local head = Char.model and Char.model:FindFirstChild("Head")
    local hrp  = Char.hrp
    if head and hrp then
        return (head.Position.Y - hrp.Position.Y)
    end
    return CONFIG.EYE_HEIGHT
end

function View.track(realCF)
    local eye = View.eye
    if not (eye and eye.Parent and realCF) then return end
    eye.CFrame = realCF + Vector3.new(0, eyeHeight(), 0)
end

function View.attach()
    local cam = workspace.CurrentCamera
    if not cam then return end
    View.ensureEye()
    if not View.on then
        View.prevSubj = cam.CameraSubject
        View.on = true
    end
    cam.CameraSubject = View.eye
end

function View.detach()
    local cam = workspace.CurrentCamera
    if cam then
        -- Hand the camera back to the Humanoid rather than to whatever was
        -- cached: on a respawn the cached subject is a corpse.
        cam.CameraSubject = Char.hum or View.prevSubj
    end
    View.prevSubj = nil
    View.on = false
    if View.eye then View.eye:Destroy(); View.eye = nil end
end

-- The stock character scripts rewrite LocalTransparencyModifier every frame
-- (that is how first person hides your own body), so ours has to be written
-- every frame too, and after theirs. RenderPriority.Character is 300; the
-- binding that calls this runs at Last.
--
-- The list is cached per character rather than walked every frame: this fires
-- 60 times a second and GetDescendants allocates a fresh table each call.
local hideList = {}

local function rebuildHideList(model)
    table.clear(hideList)
    if not model then return end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") or d:IsA("Decal") then
            table.insert(hideList, d)
        end
    end
end

local function hideSelf(hidden)
    local v = hidden and 1 or 0
    for i = #hideList, 1, -1 do
        local d = hideList[i]
        if d.Parent then
            d.LocalTransparencyModifier = v
        else
            table.remove(hideList, i)   -- accessory removed, tool unequipped
        end
    end
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
frame.Size             = UDim2.new(0, 250, 0, 152)
frame.Position         = UDim2.new(0, 12, 0.5, -76)
frame.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Draggable        = true
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size                   = UDim2.new(1, 0, 0, 26)
titleLbl.BackgroundTransparency = 1
titleLbl.Text                   = "Invisibility  ·  Ghost"
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
status.Size                   = UDim2.new(1, -20, 0, 18)
status.Position               = UDim2.new(0, 10, 0, 106)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = Color3.fromRGB(118, 118, 126)
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Font                   = Enum.Font.Code
status.TextSize               = 11
status.Parent                 = frame

local duty = Instance.new("TextLabel")
duty.Size                   = UDim2.new(1, -20, 0, 18)
duty.Position               = UDim2.new(0, 10, 0, 126)
duty.BackgroundTransparency = 1
duty.Text                   = ""
duty.TextColor3             = Color3.fromRGB(96, 96, 104)
duty.TextXAlignment         = Enum.TextXAlignment.Left
duty.Font                   = Enum.Font.Code
duty.TextSize               = 11
duty.Parent                 = frame

--=====================================================================
-- Ghost — the inverted park.
--
-- Modes:
--   "anchor"  lie sits at a fixed point       — you appear to stand still
--   "under"   lie sits UNDER_DEPTH below you  — you appear underground,
--             tracking horizontally so the server sees ordinary movement
--=====================================================================

local Ghost = {
    on        = false,
    mode      = nil,    -- "anchor" | "under"
    fixed     = nil,    -- CFrame, anchor mode
    real      = nil,    -- last known TRUE root CFrame
    realVel   = nil,
    realAng   = nil,
    stepped   = false,  -- the pre-physics truth write ran this frame
    holdKey   = false,
    hold      = 0,
    jitter    = CONFIG.JITTER,
    off       = 0,      -- offset last WRITTEN, for the readout

    -- honest duty-cycle accounting: what fraction of wall-clock the root
    -- actually held the lie. This is our side of the wire only — it bounds
    -- the delivery rate, it does not claim the server accepted anything.
    lieStart   = nil,
    truthStart = nil,
    lieAccum   = 0,
    trueAccum  = 0,
    dutyShown  = 0,

    connStep  = nil,
    connHeart = nil,
    bound     = false,
}

local function ghostTarget(realCF)
    if Ghost.mode == "under" then
        -- Below FallenPartsDestroyHeight the engine deletes parts, and a
        -- deleted root is a dead character. Stay clear of that plane while
        -- still sitting below yourself.
        local rootY  = realCF.Position.Y
        local floorY = workspace.FallenPartsDestroyHeight + CONFIG.DESTROY_CLEAR
        local y = math.min(math.max(rootY - CONFIG.UNDER_DEPTH, floorY), rootY - 4)
        return CFrame.new(realCF.Position.X, y, realCF.Position.Z)
    end
    return Ghost.fixed
end

-- PRE-PHYSICS. Put the root on the truth so the step simulates from where
-- the player really is: collision, the Humanoid state machine, floor
-- detection and movement all read this and nothing else.
local function ghostTruth()
    local hrp = Char.hrp
    if not (Ghost.on and hrp and hrp.Parent and Ghost.real) then return end

    hrp.CFrame = Ghost.real
    if Ghost.realVel then hrp.AssemblyLinearVelocity  = Ghost.realVel end
    if Ghost.realAng then hrp.AssemblyAngularVelocity = Ghost.realAng end
    Ghost.stepped = true

    if Ghost.lieStart then
        Ghost.lieAccum += clock() - Ghost.lieStart
        Ghost.lieStart = nil
    end
    Ghost.truthStart = clock()
end

-- POST-PHYSICS. Capture what the step produced, then hand the root to the
-- lie for the rest of the frame — the render block, the idle block and the
-- frame boundary, which is all of the wall-clock the 20Hz sender can sample.
local function ghostLie()
    local ok, hrp = alive()
    if not ok then return end

    -- Adopt the post-physics root as truth only if the pre-physics write
    -- actually ran. If it did not, physics did not run either and the root is
    -- still sitting on last frame's lie; adopting it would park the next lie
    -- relative to the lie, a ratchet of one step per dropped frame ending in
    -- the void.
    local stepped = Ghost.stepped
    Ghost.stepped = false
    if stepped then
        Ghost.real    = hrp.CFrame
        Ghost.realVel = hrp.AssemblyLinearVelocity
        Ghost.realAng = hrp.AssemblyAngularVelocity
    end
    if not Ghost.real then return end

    if Ghost.truthStart then
        Ghost.trueAccum += clock() - Ghost.truthStart
        Ghost.truthStart = nil
    end

    -- Resync: do not write the lie at all. The root then holds the truth for
    -- the whole frame, so every sample the sender takes carries it.
    --
    -- The nudge still matters here. Standing perfectly still, ghostTruth
    -- writes the same CFrame every frame, which is no delta and therefore no
    -- packet at all — the server would sit on the parked position for the
    -- whole hold and the resync would do nothing. Alternating sub-stud makes
    -- every frame of the hold a genuine change.
    if Ghost.holdKey or Ghost.hold > 0 then
        if not Ghost.holdKey then Ghost.hold -= 1 end
        Ghost.off = 0
        if Ghost.hold == 0 and not Ghost.holdKey and Ghost.mode == "anchor" then
            Ghost.fixed = Ghost.real   -- re-anchor wherever we surfaced
        end
        Ghost.jitter = -Ghost.jitter
        hrp.CFrame   = Ghost.real + Vector3.new(0, Ghost.jitter, 0)
        Ghost.truthStart = clock()
        return
    end

    local target = ghostTarget(Ghost.real)
    if not target then return end

    -- An identical CFrame produces no replication delta and therefore no
    -- packet. Standing still in anchor mode writes the same value forever, so
    -- alternate a sub-stud nudge and every write is a genuine change.
    Ghost.jitter = -Ghost.jitter
    target = target + Vector3.new(0, Ghost.jitter, 0)

    hrp.CFrame = target
    Ghost.off  = (target.Position - Ghost.real.Position).Magnitude
    Ghost.lieStart = clock()
end

-- RENDER, EARLY. Never touches the root. Places the camera's stand-in at the
-- true position, and must run before RenderPriority.Camera (200) reads it —
-- bound later, the camera would trail a whole frame behind.
--
-- Ghost.real is the post-physics capture from the last Heartbeat, which is
-- exactly the value the stock camera would have read off the root itself, so
-- routing the camera through the eye part costs no latency at all.
local function ghostEye()
    if not Ghost.on then return end
    View.track(Ghost.real)
end

-- RENDER, LATE. The body is drawing at the lie, so it stays hidden. This has
-- to land after RenderPriority.Character (300) or the stock character scripts
-- overwrite the modifier in the same frame.
local function ghostHide()
    if not Ghost.on then return end
    if CONFIG.HIDE_SELF then hideSelf(true) end
end

local function ghostOnChar(model)
    Ghost.real, Ghost.realVel, Ghost.realAng = nil, nil, nil
    Ghost.stepped = false
    rebuildHideList(model)
    if Ghost.mode == "anchor" then
        Ghost.fixed = Char.hrp and Char.hrp.CFrame or nil
    end
    if Ghost.on then View.attach() end
end

local function ghostStart(mode)
    if Ghost.on then return end

    local ok, hrp = alive()
    if not ok then error("no character", 0) end

    Ghost.mode    = mode
    Ghost.fixed   = hrp.CFrame
    Ghost.real    = hrp.CFrame
    Ghost.realVel = hrp.AssemblyLinearVelocity
    Ghost.realAng = hrp.AssemblyAngularVelocity
    Ghost.stepped = false
    Ghost.hold    = 0
    Ghost.off     = 0
    Ghost.lieStart, Ghost.truthStart = nil, nil
    Ghost.lieAccum, Ghost.trueAccum  = 0, 0
    Ghost.on      = true

    rebuildHideList(Char.model)

    -- Unwind fully if any binding throws, so a failure cannot strand the lie
    -- running with its button reading OFF.
    local bindOk, err = pcall(function()
        View.attach()
        Ghost.connStep  = RunService.Stepped:Connect(ghostTruth)
        Ghost.connHeart = RunService.Heartbeat:Connect(ghostLie)
        -- First (0) is ahead of RenderPriority.Camera (200), so the camera
        -- reads an eye part already placed this frame. Last (2000) is behind
        -- RenderPriority.Character (300), so our transparency is the final
        -- word rather than the stock scripts'.
        RunService:BindToRenderStep("GhostEye",  Enum.RenderPriority.First.Value, ghostEye)
        RunService:BindToRenderStep("GhostHide", Enum.RenderPriority.Last.Value,  ghostHide)
        Ghost.bound = true
    end)
    if not bindOk then
        Ghost.on = false
        if Ghost.connStep  then Ghost.connStep:Disconnect();  Ghost.connStep  = nil end
        if Ghost.connHeart then Ghost.connHeart:Disconnect(); Ghost.connHeart = nil end
        pcall(function() RunService:UnbindFromRenderStep("GhostEye")  end)
        pcall(function() RunService:UnbindFromRenderStep("GhostHide") end)
        Ghost.bound = false
        pcall(View.detach)
        pcall(hideSelf, false)
        error(err, 0)
    end
end

local function ghostStop()
    if not Ghost.on then return end
    Ghost.on = false

    if Ghost.connStep  then Ghost.connStep:Disconnect()  end
    if Ghost.connHeart then Ghost.connHeart:Disconnect() end
    Ghost.connStep, Ghost.connHeart = nil, nil
    if Ghost.bound then
        pcall(function() RunService:UnbindFromRenderStep("GhostEye")  end)
        pcall(function() RunService:UnbindFromRenderStep("GhostHide") end)
        Ghost.bound = false
    end

    pcall(View.detach)
    pcall(hideSelf, false)

    -- Leave the root on the truth, carrying its real velocity rather than
    -- whatever the last write left it holding. Nudge it so the value differs
    -- from the last one the sender took: writing a CFrame the server already
    -- has produces no delta and no packet, and the parked position would
    -- stand until the player happened to move.
    local hrp = Char.hrp
    if hrp and hrp.Parent and Ghost.real then
        Ghost.jitter = -Ghost.jitter
        hrp.CFrame = Ghost.real + Vector3.new(0, Ghost.jitter, 0)
        if Ghost.realVel then hrp.AssemblyLinearVelocity  = Ghost.realVel end
        if Ghost.realAng then hrp.AssemblyAngularVelocity = Ghost.realAng end
    end

    Ghost.mode, Ghost.fixed, Ghost.real = nil, nil, nil
    Ghost.realVel, Ghost.realAng = nil, nil
    Ghost.stepped = false
    Ghost.holdKey, Ghost.hold, Ghost.off = false, 0, 0
    Ghost.lieStart, Ghost.truthStart = nil, nil
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe or not Ghost.on then return end
    if input.KeyCode == CONFIG.RESYNC_KEY then Ghost.holdKey = true end
end)

UIS.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.RESYNC_KEY then return end
    Ghost.holdKey = false
    Ghost.hold    = CONFIG.RESYNC_FRAMES   -- tail, so a tap still lands
end)

--=====================================================================
-- The two modes.
--=====================================================================

local desyncOn, underOn = false, false

local function desyncStart() ghostStart("anchor"); desyncOn = true end
local function desyncStop()  desyncOn = false; ghostStop() end
local function underStart()  ghostStart("under");  underOn  = true end
local function underStop()   underOn  = false; ghostStop() end

--=====================================================================
-- Wiring
--=====================================================================

table.insert(Char.onChar, ghostOnChar)
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
            warn("[Ghost]", err)
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

-- The readout reports what we WROTE and how long the root actually held it.
-- Duty cycle is the honest number here: it is the ceiling on how often the
-- 20Hz sender can possibly have sampled the lie, measured on our side of the
-- wire. It is not a claim that the server accepted anything — an early build
-- showed a drift figure derived purely from local position, which climbed
-- whenever he walked and made a dead desync look alive for two rounds. Only
-- a second client confirms delivery.
local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if not Ghost.on then
        status.Text = "idle"
        duty.Text   = ""
        return
    end

    if Ghost.holdKey or Ghost.hold > 0 then
        status.Text = "RESYNC — lie suspended"
        duty.Text   = "root holds truth all frame"
        return
    end

    statusClock += dt
    if statusClock < 0.25 then return end
    statusClock = 0

    local total = Ghost.lieAccum + Ghost.trueAccum
    if total > 0 then
        Ghost.dutyShown = (Ghost.lieAccum / total) * 100
        Ghost.lieAccum, Ghost.trueAccum = 0, 0
    end

    status.Text = string.format("%s sent %.0fst off  [hold %s]",
        Ghost.mode, Ghost.off, CONFIG.RESYNC_KEY.Name)
    duty.Text = string.format("lie held %.1f%% of frame (our side)", Ghost.dutyShown)
end)

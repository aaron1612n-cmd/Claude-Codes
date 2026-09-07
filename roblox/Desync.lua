--[[
    Desync.lua — Universal Roblox Desync
    Splits client position from server-replicated position.
    Works in any executor that exposes the standard Roblox globals.

    Toggle: [F] keybind or GUI button
    WASD to move, Space to ascend, LeftControl to descend.

    The anchor position is locked when desync activates. Your client flies
    freely; the server keeps receiving the anchor. Turning it off drops you
    where you actually walked.
--]]

local CONFIG = {
    ToggleKey  = Enum.KeyCode.F,
    AscendKey  = Enum.KeyCode.Space,
    DescendKey = Enum.KeyCode.LeftControl,
    Speed      = 50,    -- studs/s while desynced
    -- true  = turning desync off drops you where you walked (apparent teleport)
    -- false = you snap back to the anchor the server saw the whole time
    TeleportOnDisable = true,
}

-- ── Services ──────────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local StarterGui       = game:GetService("StarterGui")

local lp = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────
local active        = false
local anchorCF      = CFrame.new()
local clientCF      = CFrame.new()  -- visual position, independent of replication
local heartbeatConn = nil
local char, root, humanoid

-- ── GUI ───────────────────────────────────────────────────────────────────────
-- Built immediately so it appears even if the character isn't loaded yet.

local sg = Instance.new("ScreenGui")
sg.Name           = "DesyncGUI"
sg.ResetOnSpawn   = false
sg.IgnoreGuiInset = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local ok = pcall(function() sg.Parent = game:GetService("CoreGui") end)
if not ok then
    sg.Parent = lp:WaitForChild("PlayerGui")
end

-- Window frame
local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(220, 100)
frame.Position         = UDim2.fromOffset(20, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel  = 0
frame.Parent           = sg

Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke", frame)
stroke.Color     = Color3.fromRGB(60, 60, 75)
stroke.Thickness = 1

-- Title bar (drag handle)
local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 28)
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
titleLabel.Size                   = UDim2.new(1, -8, 1, 0)
titleLabel.Position               = UDim2.fromOffset(8, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font                   = Enum.Font.GothamBold
titleLabel.TextSize               = 13
titleLabel.TextColor3             = Color3.fromRGB(180, 180, 200)
titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
titleLabel.Text                   = "DESYNC"
titleLabel.Parent                 = titleBar

-- Status label
local statusLabel = Instance.new("TextLabel")
statusLabel.Size                   = UDim2.new(1, -16, 0, 20)
statusLabel.Position               = UDim2.fromOffset(8, 34)
statusLabel.BackgroundTransparency = 1
statusLabel.Font                   = Enum.Font.Gotham
statusLabel.TextSize               = 12
statusLabel.TextColor3             = Color3.fromRGB(120, 120, 140)
statusLabel.TextXAlignment         = Enum.TextXAlignment.Left
statusLabel.Text                   = "Status: Inactive"
statusLabel.Parent                 = frame

-- Toggle button
local btn = Instance.new("TextButton")
btn.Size             = UDim2.new(1, -16, 0, 34)
btn.Position         = UDim2.fromOffset(8, 58)
btn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
btn.BorderSizePixel  = 0
btn.Font             = Enum.Font.GothamBold
btn.TextSize         = 13
btn.TextColor3       = Color3.fromRGB(200, 200, 220)
btn.Text             = "ENABLE  [F]"
btn.AutoButtonColor  = false
btn.Parent           = frame

Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

local btnStroke = Instance.new("UIStroke", btn)
btnStroke.Color     = Color3.fromRGB(60, 60, 75)
btnStroke.Thickness = 1

-- Hover tweens
local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)

btn.MouseEnter:Connect(function()
    TweenService:Create(btn, tweenInfo, {
        BackgroundColor3 = Color3.fromRGB(50, 50, 65)
    }):Play()
end)

btn.MouseLeave:Connect(function()
    TweenService:Create(btn, tweenInfo, {
        BackgroundColor3 = active
            and Color3.fromRGB(30, 90, 50)
            or  Color3.fromRGB(35, 35, 45)
    }):Play()
end)

-- Drag
local dragging, dragStart, startPos = false, nil, nil

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging  = true
        dragStart = input.Position
        startPos  = frame.Position
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

-- ── UI state helper ───────────────────────────────────────────────────────────
local function updateUI(on)
    if on then
        statusLabel.Text       = "Status: ACTIVE"
        statusLabel.TextColor3 = Color3.fromRGB(80, 220, 100)
        btn.Text               = "DISABLE  [F]"
        btn.TextColor3         = Color3.fromRGB(80, 220, 100)
        TweenService:Create(btn,      tweenInfo, { BackgroundColor3 = Color3.fromRGB(30, 90, 50)    }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color            = Color3.fromRGB(50, 160, 80)  }):Play()
    else
        statusLabel.Text       = "Status: Inactive"
        statusLabel.TextColor3 = Color3.fromRGB(120, 120, 140)
        btn.Text               = "ENABLE  [F]"
        btn.TextColor3         = Color3.fromRGB(200, 200, 220)
        TweenService:Create(btn,      tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45)    }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color            = Color3.fromRGB(60, 60, 75)   }):Play()
    end
end

-- ── Core ──────────────────────────────────────────────────────────────────────
--
-- Frame order in Roblox, and where each write has to land:
--
--   1. BindToRenderStep / RenderStepped   <- write clientCF here (what you SEE)
--   2. render
--   3. Stepped            (pre-physics)
--   4. physics simulation
--   5. Heartbeat          (post-physics)  <- write anchorCF here (what SERVER sees)
--   6. replication flush
--
-- The replicator sends whatever state the part holds when the flush runs, so
-- the anchorCF write must be the LAST one of the frame — that means Heartbeat,
-- not Stepped. The visual write must land before the camera module samples the
-- root, which is why it's a BindToRenderStep at Camera-1 rather than a plain
-- RenderStepped connection (connection order against the camera is otherwise
-- undefined).
--
-- The root is also anchored while active. Without that, gravity keeps
-- accumulating velocity on an assembly we teleport every step: the humanoid
-- drops into Freefall and the camera lerps toward a subject being yanked
-- between two positions every frame.

local RENDER_BIND    = "DesyncVisual"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value - 1

local savedAnchored, savedWalkSpeed, savedJumpPower

local keyMap = {
    [Enum.KeyCode.W] = Vector3.new( 0, 0, -1),
    [Enum.KeyCode.S] = Vector3.new( 0, 0,  1),
    [Enum.KeyCode.A] = Vector3.new(-1, 0,  0),
    [Enum.KeyCode.D] = Vector3.new( 1, 0,  0),
}

local function killVelocity()
    if not root then return end
    root.AssemblyLinearVelocity  = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

-- Advance clientCF from input, then place the root there for this frame's render.
local function stepVisual(dt)
    if not active or not root then return end

    local dir = Vector3.zero
    for key, vec in pairs(keyMap) do
        if UserInputService:IsKeyDown(key) then
            dir += vec
        end
    end

    -- Flatten the camera look onto the XZ plane. Looking straight up or down
    -- flattens to a zero vector, which would make .Unit NaN and corrupt the
    -- CFrame permanently — fall back to the character's current facing.
    local cam  = workspace.CurrentCamera
    local flat = cam.CFrame.LookVector * Vector3.new(1, 0, 1)
    if flat.Magnitude < 1e-4 then
        flat = clientCF.LookVector * Vector3.new(1, 0, 1)
        if flat.Magnitude < 1e-4 then
            flat = Vector3.new(0, 0, -1)
        end
    end
    local camYaw = CFrame.lookAt(Vector3.zero, flat.Unit)

    if dir.Magnitude > 0 then
        local worldDir = camYaw:VectorToWorldSpace(dir.Unit)
        local newPos   = clientCF.Position + worldDir * CONFIG.Speed * dt
        clientCF = CFrame.lookAt(newPos, newPos + camYaw.LookVector)
    end

    if UserInputService:IsKeyDown(CONFIG.AscendKey) then
        clientCF = clientCF + Vector3.new(0,  CONFIG.Speed * dt, 0)
    end
    if UserInputService:IsKeyDown(CONFIG.DescendKey) then
        clientCF = clientCF + Vector3.new(0, -CONFIG.Speed * dt, 0)
    end

    root.CFrame = clientCF
end

local function enable()
    if active then return end

    -- Never fail silently: a missing character is the difference between
    -- "the button is broken" and "wait a second for the character to load".
    if not root or not root.Parent or not humanoid then
        statusLabel.Text       = "Status: no character"
        statusLabel.TextColor3 = Color3.fromRGB(220, 160, 60)
        return
    end

    active   = true
    anchorCF = root.CFrame
    clientCF = root.CFrame

    -- Freeze the assembly: no gravity, no accumulated velocity, no humanoid
    -- state machine fighting our writes.
    savedAnchored  = root.Anchored
    savedWalkSpeed = humanoid.WalkSpeed
    savedJumpPower = humanoid.JumpPower

    root.Anchored      = true
    humanoid.WalkSpeed = 0
    humanoid.JumpPower = 0
    killVelocity()

    -- Visual position, written just before the camera reads the root.
    RunService:BindToRenderStep(RENDER_BIND, RENDER_PRIORITY, stepVisual)

    -- Replicated position, written last in the frame so the flush sends it.
    heartbeatConn = RunService.Heartbeat:Connect(function()
        if not active or not root then return end
        root.CFrame = anchorCF
        killVelocity()
    end)

    updateUI(true)

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = "Active — server anchor locked", Duration = 2,
        })
    end)
end

local function disable()
    if not active then return end
    active = false

    pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end)

    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    if root then
        -- Land where you walked, or snap back to the anchor.
        root.CFrame  = CONFIG.TeleportOnDisable and clientCF or anchorCF
        root.Anchored = savedAnchored or false
        killVelocity()
    end

    if humanoid then
        humanoid.WalkSpeed = savedWalkSpeed or 16
        humanoid.JumpPower = savedJumpPower or 50
    end

    updateUI(false)

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = "Disabled — back in sync", Duration = 2,
        })
    end)
end

local function toggle()
    if active then disable() else enable() end
end

-- ── Character init (async — GUI is already up) ────────────────────────────────
local function bindCharacter(c)
    char     = c
    root     = c:WaitForChild("HumanoidRootPart")
    humanoid = c:WaitForChild("Humanoid")
end

task.spawn(function()
    bindCharacter(lp.Character or lp.CharacterAdded:Wait())
end)

lp.CharacterAdded:Connect(function(newChar)
    -- Drop state without touching the old (now destroyed) character.
    active = false
    pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end)
    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end
    savedAnchored, savedWalkSpeed, savedJumpPower = nil, nil, nil

    -- bindCharacter yields on WaitForChild; clear the stale refs first so
    -- nothing touches the destroyed character during that window.
    root, humanoid = nil, nil
    updateUI(false)

    bindCharacter(newChar)
end)

-- ── Input ─────────────────────────────────────────────────────────────────────
btn.MouseButton1Click:Connect(toggle)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.ToggleKey then toggle() end
end)

-- ── Public API ────────────────────────────────────────────────────────────────
return {
    enable  = enable,
    disable = disable,
    toggle  = toggle,
    active  = function() return active end,
}

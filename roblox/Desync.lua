--[[
    Desync.lua — Universal Roblox Desync

    You walk around completely normally. The humanoid is never touched, so
    movement, animations, collision and the camera all stay native. The only
    thing that changes is what the server receives.

    Mechanism
    ---------
    Frame order on the client:

        RenderStepped -> render -> Stepped -> physics -> Heartbeat -> replication flush

    Heartbeat is the last thing that runs before the engine transmits property
    updates, and it is not part of the rendering pipeline. So:

        Heartbeat     : save the real CFrame, write the spoofed one
                        -> the flush sends the spoofed position
        RenderStepped : write the real CFrame back
                        -> the frame draws at the real position

    The character sits at the spoofed position only in the gap between the
    replication flush and the next frame, which is neither rendered nor
    simulated. Locally nothing changes; to the server and every other player
    you are frozen where you switched it on.

    Toggle with the GUI button or [F].
--]]

local CONFIG = {
    ToggleKey    = Enum.KeyCode.F,
    Jitter       = false,  -- scatter the spoofed position instead of pinning it
    JitterRadius = 12,     -- studs, when Jitter is on
}

-- ── Services ──────────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local StarterGui       = game:GetService("StarterGui")

local lp = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────
local active   = false
local anchorCF = CFrame.new()   -- where the server thinks you are

-- The genuine client-side state, captured every Heartbeat before we overwrite
-- it and restored every RenderStepped. Never driven by us — the humanoid owns
-- it, we only borrow it for the length of a replication flush.
local realCF, realVel, realAngVel

local heartbeatConn = nil
local root, humanoid

local RESTORE_BIND = "DesyncRestore"

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
frame.Size             = UDim2.fromOffset(240, 158)
frame.Position         = UDim2.fromOffset(20, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel  = 0
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke", frame)
stroke.Color, stroke.Thickness = Color3.fromRGB(60, 60, 75), 1

-- Title bar doubles as the drag handle.
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

local statusLabel = Instance.new("TextLabel")
statusLabel.Size                   = UDim2.new(1, -20, 0, 18)
statusLabel.Position               = UDim2.fromOffset(10, 36)
statusLabel.BackgroundTransparency = 1
statusLabel.Font                   = Enum.Font.Gotham
statusLabel.TextSize               = 12
statusLabel.TextColor3             = Color3.fromRGB(120, 120, 140)
statusLabel.TextXAlignment         = Enum.TextXAlignment.Left
statusLabel.Text                   = "Status: Inactive"
statusLabel.Parent                 = frame

-- 44px tall: a real touch target, since this has to be usable on mobile.
local btn = Instance.new("TextButton")
btn.Size             = UDim2.new(1, -20, 0, 44)
btn.Position         = UDim2.fromOffset(10, 58)
btn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
btn.BorderSizePixel  = 0
btn.Font             = Enum.Font.GothamBold
btn.TextSize         = 14
btn.TextColor3       = Color3.fromRGB(200, 200, 220)
btn.Text             = "ENABLE"
btn.AutoButtonColor  = false
btn.Parent           = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

local btnStroke = Instance.new("UIStroke", btn)
btnStroke.Color, btnStroke.Thickness = Color3.fromRGB(60, 60, 75), 1

local jitterBtn = Instance.new("TextButton")
jitterBtn.Size             = UDim2.new(1, -20, 0, 36)
jitterBtn.Position         = UDim2.fromOffset(10, 110)
jitterBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
jitterBtn.BorderSizePixel  = 0
jitterBtn.Font             = Enum.Font.Gotham
jitterBtn.TextSize         = 12
jitterBtn.TextColor3       = Color3.fromRGB(150, 150, 170)
jitterBtn.Text             = "Jitter: OFF"
jitterBtn.AutoButtonColor  = false
jitterBtn.Parent           = frame
Instance.new("UICorner", jitterBtn).CornerRadius = UDim.new(0, 6)

local jitterStroke = Instance.new("UIStroke", jitterBtn)
jitterStroke.Color, jitterStroke.Thickness = Color3.fromRGB(50, 50, 62), 1

local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)

btn.MouseEnter:Connect(function()
    if active then return end
    TweenService:Create(btn, tweenInfo, { BackgroundColor3 = Color3.fromRGB(50, 50, 65) }):Play()
end)
btn.MouseLeave:Connect(function()
    TweenService:Create(btn, tweenInfo, {
        BackgroundColor3 = active and Color3.fromRGB(30, 90, 50) or Color3.fromRGB(35, 35, 45)
    }):Play()
end)

-- Drag, mouse and touch alike.
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

local function updateUI(on)
    if on then
        statusLabel.Text, statusLabel.TextColor3 = "Status: ACTIVE", Color3.fromRGB(80, 220, 100)
        btn.Text, btn.TextColor3 = "DISABLE", Color3.fromRGB(80, 220, 100)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(30, 90, 50) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(50, 160, 80) }):Play()
    else
        statusLabel.Text, statusLabel.TextColor3 = "Status: Inactive", Color3.fromRGB(120, 120, 140)
        btn.Text, btn.TextColor3 = "ENABLE", Color3.fromRGB(200, 200, 220)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(60, 60, 75) }):Play()
    end
end

local function updateJitterUI()
    jitterBtn.Text = CONFIG.Jitter and "Jitter: ON" or "Jitter: OFF"
    jitterBtn.TextColor3 = CONFIG.Jitter
        and Color3.fromRGB(230, 180, 90)
        or  Color3.fromRGB(150, 150, 170)
    TweenService:Create(jitterStroke, tweenInfo, {
        Color = CONFIG.Jitter and Color3.fromRGB(160, 120, 60) or Color3.fromRGB(50, 50, 62)
    }):Play()
end

-- ── Core ──────────────────────────────────────────────────────────────────────

local function alive()
    return root ~= nil and root.Parent ~= nil
end

-- The position handed to the server. Pinned to the anchor, or scattered around
-- it when jitter is on — a moving target breaks hit registration harder than a
-- static one, at the cost of being obvious to anyone watching.
local function spoofTarget()
    if not CONFIG.Jitter then return anchorCF end
    local r = CONFIG.JitterRadius
    return anchorCF * CFrame.new(
        (math.random() * 2 - 1) * r,
        (math.random() * 2 - 1) * r,
        (math.random() * 2 - 1) * r
    )
end

-- Restore the genuine state. Runs first thing every frame, and again on
-- disable, so the character is never left sitting at the spoofed position.
local function restoreReal()
    if not alive() or not realCF then return end
    root.CFrame                  = realCF
    root.AssemblyLinearVelocity  = realVel or Vector3.zero
    root.AssemblyAngularVelocity = realAngVel or Vector3.zero
end

local function enable()
    if active then return end

    if not alive() or not humanoid then
        statusLabel.Text       = "Status: no character"
        statusLabel.TextColor3 = Color3.fromRGB(220, 160, 60)
        return
    end

    active   = true
    anchorCF = root.CFrame
    realCF, realVel, realAngVel = nil, nil, nil

    -- Last thing before the engine transmits: swap in the spoofed position.
    -- Velocity is zeroed too, otherwise the server extrapolates the character
    -- away from the anchor between packets and the freeze drifts.
    heartbeatConn = RunService.Heartbeat:Connect(function()
        if not active or not alive() then return end

        realCF     = root.CFrame
        realVel    = root.AssemblyLinearVelocity
        realAngVel = root.AssemblyAngularVelocity

        root.CFrame                  = spoofTarget()
        root.AssemblyLinearVelocity  = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    -- First thing next frame, before the camera reads the root and before
    -- physics steps: put the real state back.
    RunService:BindToRenderStep(RESTORE_BIND, Enum.RenderPriority.First.Value, restoreReal)

    updateUI(true)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = "Active — server pinned to anchor", Duration = 2,
        })
    end)
end

local function teardown()
    active = false
    pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end
end

local function disable()
    if not active then return end
    teardown()

    -- Disabling can land in the window between the Heartbeat swap and the next
    -- frame's restore, so put the real state back explicitly rather than
    -- stranding the character at the spoofed position.
    restoreReal()
    realCF, realVel, realAngVel = nil, nil, nil

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

-- ── Character binding ─────────────────────────────────────────────────────────
local function bindCharacter(c)
    root     = c:WaitForChild("HumanoidRootPart")
    humanoid = c:WaitForChild("Humanoid")
end

task.spawn(function()
    bindCharacter(lp.Character or lp.CharacterAdded:Wait())
end)

lp.CharacterAdded:Connect(function(newChar)
    -- Drop everything without touching the old, now-destroyed character, and
    -- clear the refs before bindCharacter yields on WaitForChild.
    teardown()
    realCF, realVel, realAngVel = nil, nil, nil
    root, humanoid = nil, nil
    updateUI(false)

    bindCharacter(newChar)
end)

-- ── Input ─────────────────────────────────────────────────────────────────────
-- Activated rather than MouseButton1Click: it covers taps as well as clicks,
-- so the GUI is the whole interface on a device with no keyboard.
btn.Activated:Connect(toggle)

jitterBtn.Activated:Connect(function()
    CONFIG.Jitter = not CONFIG.Jitter
    updateJitterUI()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.ToggleKey then toggle() end
end)

updateJitterUI()

-- ── Public API ────────────────────────────────────────────────────────────────
return {
    enable  = enable,
    disable = disable,
    toggle  = toggle,
    active  = function() return active end,
    setAnchor = function(cf) anchorCF = cf end,
}

--[[
    Desync.lua — Universal Roblox Desync
    Splits client position from server-replicated position.
    Works in any executor that exposes the standard Roblox globals.

    Toggle: [F] keybind or GUI button
    The anchor position is locked when desync activates.
    Your client walks freely; server sees you frozen at the anchor.
--]]

local CONFIG = {
    ToggleKey = Enum.KeyCode.F,
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
local function freezeHumanoid(freeze)
    if not humanoid then return end
    humanoid.WalkSpeed = freeze and 0 or 16
    humanoid.JumpPower = freeze and 0 or 50
end

local function enable()
    if active or not root then return end
    active   = true
    anchorCF = root.CFrame
    clientCF = root.CFrame  -- start client visual at same spot

    freezeHumanoid(true)

    heartbeatConn = RunService.Stepped:Connect(function()
        if not active then return end
        root.CFrame = anchorCF
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

    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    freezeHumanoid(false)
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

-- ── Movement while desynced ───────────────────────────────────────────────────
local SPEED  = 16

local keyMap = {
    [Enum.KeyCode.W] = Vector3.new( 0, 0, -1),
    [Enum.KeyCode.S] = Vector3.new( 0, 0,  1),
    [Enum.KeyCode.A] = Vector3.new(-1, 0,  0),
    [Enum.KeyCode.D] = Vector3.new( 1, 0,  0),
}

RunService.RenderStepped:Connect(function(dt)
    if not active or not root then return end

    -- Accumulate movement into clientCF (not root.CFrame, which Stepped
    -- resets to anchorCF every tick for replication).
    local dir = Vector3.new()
    for key, vec in pairs(keyMap) do
        if UserInputService:IsKeyDown(key) then
            dir = dir + vec
        end
    end

    if dir.Magnitude > 0 then
        dir = dir.Unit
        local cam      = workspace.CurrentCamera
        local camYaw   = CFrame.new(Vector3.zero, cam.CFrame.LookVector * Vector3.new(1, 0, 1))
        local worldDir = camYaw:VectorToWorldSpace(dir)
        local newPos   = clientCF.Position + worldDir * SPEED * dt
        clientCF       = CFrame.new(newPos, newPos + camYaw.LookVector)
    end

    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        clientCF = clientCF + Vector3.new(0, SPEED * dt * 1.5, 0)
    end

    -- Apply visual position right before render (after Stepped already set anchorCF).
    root.CFrame = clientCF
end)

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
    disable()
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

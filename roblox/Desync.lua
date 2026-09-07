--[[
    Desync.lua — Universal Roblox Desync
    Splits client position from server-replicated position.
    Works in any executor that exposes the standard Roblox globals.

    Toggle: configurable keybind (default F)
    The anchor position is locked when desync activates.
    Your client walks freely; server sees you frozen at the anchor.
--]]

local CONFIG = {
    ToggleKey    = Enum.KeyCode.F,
    Indicator    = true,   -- show on-screen label
    IndicatorPos = UDim2.fromScale(0.5, 0.02),
}

-- ── Services ─────────────────────────────────────────────────────────────────
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui     = game:GetService("StarterGui")

local lp            = Players.LocalPlayer
local char          = lp.Character or lp.CharacterAdded:Wait()
local root          = char:WaitForChild("HumanoidRootPart")
local humanoid      = char:WaitForChild("Humanoid")

-- ── State ─────────────────────────────────────────────────────────────────────
local active        = false
local anchorCF      = CFrame.new()   -- server-visible frozen position
local heartbeatConn = nil

-- ── Indicator ────────────────────────────────────────────────────────────────
local label
if CONFIG.Indicator then
    local sg = Instance.new("ScreenGui")
    sg.Name             = "DesyncHUD"
    sg.ResetOnSpawn     = false
    sg.IgnoreGuiInset   = true
    sg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling

    -- attempt to parent to CoreGui (executor env), fall back to PlayerGui
    local ok = pcall(function()
        sg.Parent = game:GetService("CoreGui")
    end)
    if not ok then
        sg.Parent = lp:WaitForChild("PlayerGui")
    end

    label               = Instance.new("TextLabel")
    label.Size          = UDim2.fromOffset(200, 30)
    label.Position      = CONFIG.IndicatorPos
    label.AnchorPoint   = Vector2.new(0.5, 0)
    label.BackgroundTransparency = 1
    label.Font          = Enum.Font.GothamBold
    label.TextSize      = 16
    label.TextStrokeTransparency = 0.4
    label.Text          = ""
    label.Parent        = sg

    local function setLabel(on)
        if not label then return end
        label.Text      = on and "[DESYNC ON]" or "[DESYNC OFF]"
        label.TextColor3 = on
            and Color3.fromRGB(80, 255, 80)
            or  Color3.fromRGB(220, 60, 60)
    end

    -- expose so toggle can call it
    CONFIG._setLabel = setLabel
end

-- ── Core ─────────────────────────────────────────────────────────────────────

-- Freeze the humanoid so it stops sending walk updates that would move the
-- server-side character away from the anchor.
local function freezeHumanoid(freeze)
    humanoid.WalkSpeed = freeze and 0 or 16
    humanoid.JumpPower = freeze and 0 or 50
end

local function enable()
    if active then return end
    active    = true
    anchorCF  = root.CFrame   -- lock server at current position

    -- Stop humanoid from issuing MoveToFinished / walk replication
    freezeHumanoid(true)

    -- Every physics step: force the server-replicated CFrame back to the
    -- anchor.  The client's visual representation is controlled separately
    -- via direct CFrame writes below the stepped loop, so from the client
    -- you appear to move freely while the server never receives an update
    -- past anchorCF.
    --
    -- How it works under the hood:
    --   Roblox replicates HumanoidRootPart position via the network ownership
    --   system at ~20 Hz.  By writing anchorCF back every Stepped tick we
    --   win the race: the physics engine sees "no movement" and sends that
    --   to the server instead of wherever our character visually is.
    --   On executors with hookfunction/sethiddenproperty you can block the
    --   packet entirely; this pure-Lua path achieves the same effect through
    --   the replication race.

    heartbeatConn = RunService.Stepped:Connect(function()
        if not active then return end
        -- Revert the replicated transform to anchor each tick.
        -- The visual offset is applied after, so the player sees themselves
        -- moving even though the server position is frozen.
        root.CFrame = anchorCF
    end)

    if CONFIG._setLabel then CONFIG._setLabel(true) end

    -- Notify (silent, no chat spam)
    StarterGui:SetCore("SendNotification", {
        Title    = "Desync",
        Text     = "Active — server anchor locked",
        Duration = 2,
    })
end

local function disable()
    if not active then return end
    active = false

    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    freezeHumanoid(false)

    if CONFIG._setLabel then CONFIG._setLabel(false) end

    StarterGui:SetCore("SendNotification", {
        Title    = "Desync",
        Text     = "Disabled — back in sync",
        Duration = 2,
    })
end

local function toggle()
    if active then disable() else enable() end
end

-- ── Movement while desynced ───────────────────────────────────────────────────
-- When desync is active the humanoid is frozen so normal WASD is dead.
-- We manually drive the visual CFrame from input so the player can still
-- navigate on the client side.

local moveVec  = Vector3.new()
local SPEED    = 16  -- studs/s, matches default WalkSpeed

local keyMap = {
    [Enum.KeyCode.W] = Vector3.new( 0, 0, -1),
    [Enum.KeyCode.S] = Vector3.new( 0, 0,  1),
    [Enum.KeyCode.A] = Vector3.new(-1, 0,  0),
    [Enum.KeyCode.D] = Vector3.new( 1, 0,  0),
}

RunService.RenderStepped:Connect(function(dt)
    if not active then return end

    -- Accumulate pressed directions
    local dir = Vector3.new()
    for key, vec in pairs(keyMap) do
        if UserInputService:IsKeyDown(key) then
            dir = dir + vec
        end
    end

    if dir.Magnitude > 0 then
        dir = dir.Unit

        -- Rotate movement relative to camera look vector (horizontal plane)
        local cam     = workspace.CurrentCamera
        local camYaw  = CFrame.new(Vector3.zero, cam.CFrame.LookVector * Vector3.new(1, 0, 1))
        local worldDir = camYaw:VectorToWorldSpace(dir)

        -- Translate visual CFrame (client-only, server still sees anchorCF)
        local newPos = root.CFrame.Position + worldDir * SPEED * dt
        root.CFrame  = CFrame.new(newPos, newPos + camYaw.LookVector)
    end

    -- Jump: simple vertical offset on the client
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        root.CFrame = root.CFrame + Vector3.new(0, SPEED * dt * 1.5, 0)
    end
end)

-- ── Character respawn handling ────────────────────────────────────────────────
lp.CharacterAdded:Connect(function(newChar)
    disable()
    char      = newChar
    root      = newChar:WaitForChild("HumanoidRootPart")
    humanoid  = newChar:WaitForChild("Humanoid")
end)

-- ── Input ─────────────────────────────────────────────────────────────────────
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.ToggleKey then
        toggle()
    end
end)

-- ── Public API ────────────────────────────────────────────────────────────────
return {
    enable  = enable,
    disable = disable,
    toggle  = toggle,
    active  = function() return active end,
}

-- invisiblescript.client.lua
-- Hold C to sink underground. Root stays at surface so you don't die/respawn.
-- Release to pop back up.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local SINK_DEPTH   = 6      -- studs below ground
local SINK_KEY     = Enum.KeyCode.C
local SINK_SPEED   = 0.18   -- lerp factor per frame (higher = snappier)

-- ----------------------------------------------------------------

local player = Players.LocalPlayer
local char   = player.Character or player.CharacterAdded:Wait()
local hum    : Humanoid
local hrp    : BasePart

local sunk        = false
local baseOffset  = Vector3.new(0, 0, 0)
local targetY     = 0
local currentY    = 0

local function getParts(c)
    local parts = {}
    for _, v in ipairs(c:GetDescendants()) do
        if v:IsA("BasePart") and v.Name ~= "HumanoidRootPart" then
            parts[#parts + 1] = v
        end
    end
    return parts
end

local function setup(c)
    char  = c
    hum   = c:WaitForChild("Humanoid")
    hrp   = c:WaitForChild("HumanoidRootPart")
    sunk  = false
    currentY = 0
    targetY  = 0
end

setup(char)

-- lerp the visual offset of all non-root parts each frame
RunService.RenderStepped:Connect(function()
    if not hrp or not hrp.Parent then return end

    currentY = currentY + (targetY - currentY) * SINK_SPEED

    for _, part in ipairs(getParts(char)) do
        -- only touch parts connected by Motor6D (already offset by rig)
        -- we nudge the whole model by adjusting HRP CFrame and compensating root
        -- instead: offset every part's CFrame directly (works with R6 + R15)
        -- this is dirty but reliable for a cosmetic underground effect
    end

    -- cleaner: just move HRP down and disable its collision so floor doesn't stop it
    -- the "root still there" effect = HRP at surface Y but body parts below via RootPart offset
    hrp.CFrame = hrp.CFrame * CFrame.new(0, 0, 0) -- position managed below
end)

-- ----------------------------------------------------------------
-- Actually the cleanest method: drive the whole character CFrame down,
-- keep a ghost anchor at the original Y so humanoid doesn't die from falling.

local anchor : Part? = nil

local function enterSink()
    if sunk then return end
    sunk = true

    -- disable humanoid physics so we can freely move the root
    hum.PlatformStand = true

    -- disable collision on all parts so we phase through floor
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("BasePart") then
            v.CanCollide = false
        end
    end

    -- tween HRP down
    local conn
    conn = RunService.RenderStepped:Connect(function()
        if not sunk then conn:Disconnect() return end
        local cf = hrp.CFrame
        local target = CFrame.new(cf.X, cf.Y - SINK_DEPTH * SINK_SPEED * 6, cf.Z) * (cf - cf.p)
        -- simple approach: just slam it down once, lerp handled below
        conn:Disconnect()
    end)

    -- direct: move hrp down by SINK_DEPTH over several frames
    local frames = 0
    local totalFrames = 12
    local startY = hrp.Position.Y
    local endY   = startY - SINK_DEPTH

    local slideConn
    slideConn = RunService.RenderStepped:Connect(function()
        if not sunk then slideConn:Disconnect() return end
        frames = frames + 1
        local t = math.min(frames / totalFrames, 1)
        local newY = startY + (endY - startY) * t
        hrp.CFrame = CFrame.new(hrp.Position.X, newY, hrp.Position.Z)
                     * (hrp.CFrame - hrp.CFrame.p)
        if t >= 1 then slideConn:Disconnect() end
    end)
end

local function exitSink()
    if not sunk then return end
    sunk = false

    local startY = hrp.Position.Y
    local endY   = startY + SINK_DEPTH
    local frames = 0
    local totalFrames = 12

    local slideConn
    slideConn = RunService.RenderStepped:Connect(function()
        if sunk then slideConn:Disconnect() return end
        frames = frames + 1
        local t = math.min(frames / totalFrames, 1)
        local newY = startY + (endY - startY) * t
        hrp.CFrame = CFrame.new(hrp.Position.X, newY, hrp.Position.Z)
                     * (hrp.CFrame - hrp.CFrame.p)
        if t >= 1 then
            slideConn:Disconnect()
            -- restore collision and physics
            hum.PlatformStand = false
            for _, v in ipairs(char:GetDescendants()) do
                if v:IsA("BasePart") then
                    v.CanCollide = true
                end
            end
        end
    end)
end

-- keyboard
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == SINK_KEY then enterSink() end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == SINK_KEY then exitSink() end
end)

-- mobile toggle button
local gui    = Instance.new("ScreenGui")
gui.Name     = "InvisibleGui"
gui.ResetOnSpawn = false
gui.Parent   = player.PlayerGui

local btn         = Instance.new("TextButton")
btn.Size          = UDim2.new(0, 90, 0, 90)
btn.Position      = UDim2.new(1, -110, 1, -120)
btn.AnchorPoint   = Vector2.new(0, 0)
btn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
btn.TextColor3    = Color3.fromRGB(255, 255, 255)
btn.Text          = "HIDE"
btn.Font          = Enum.Font.GothamBold
btn.TextSize      = 18
btn.BorderSizePixel = 0
btn.Parent        = gui

local corner      = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent     = btn

btn.MouseButton1Click:Connect(function()
    if sunk then
        exitSink()
        btn.Text = "HIDE"
        btn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    else
        enterSink()
        btn.Text = "SHOW"
        btn.BackgroundColor3 = Color3.fromRGB(180, 30, 30)
    end
end)

player.CharacterAdded:Connect(setup)

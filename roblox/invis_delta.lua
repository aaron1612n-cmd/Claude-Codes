-- roblox/invis_delta.lua
-- Delta executor exploit script
-- Two independent invisibility methods, each with its own GUI toggle.
-- HumanoidRootPart is always left alone so server-side hitbox and tools stay intact.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp         = Players.LocalPlayer

-- ── GUI ───────────────────────────────────────────────────────────────────────

local sg = Instance.new("ScreenGui")
sg.Name          = "InvisGUI"
sg.ResetOnSpawn  = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local frame = Instance.new("Frame")
frame.Size            = UDim2.new(0, 230, 0, 96)
frame.Position        = UDim2.new(0, 10, 0.5, -48)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
frame.BorderSizePixel = 0
frame.Active          = true
frame.Draggable       = true
frame.Parent          = sg

do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 7)
    c.Parent = frame
end

local titleLbl = Instance.new("TextLabel")
titleLbl.Size             = UDim2.new(1, 0, 0, 26)
titleLbl.BackgroundTransparency = 1
titleLbl.Text             = "Invisibility  [Delta]"
titleLbl.TextColor3       = Color3.fromRGB(210, 210, 210)
titleLbl.Font             = Enum.Font.GothamBold
titleLbl.TextSize         = 12
titleLbl.Parent           = frame

local function makeBtn(label, yOff)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -20, 0, 30)
    btn.Position         = UDim2.new(0, 10, 0, yOff)
    btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    btn.BorderSizePixel  = 0
    btn.Text             = label .. ": OFF"
    btn.TextColor3       = Color3.fromRGB(175, 175, 175)
    btn.Font             = Enum.Font.Gotham
    btn.TextSize         = 12
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 5)
    c.Parent = btn
    btn.Parent = frame
    return btn
end

local btn1 = makeBtn("LTM Loop",    28)   -- method 1
local btn2 = makeBtn("Hook __index", 62)  -- method 2

-- ── Shared helper ─────────────────────────────────────────────────────────────

local function eachPart(char, fn)
    if not char then return end
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("BasePart") and v.Name ~= "HumanoidRootPart" then
            fn(v)
        end
    end
end

-- ── Method 1 — LocalTransparencyModifier loop ─────────────────────────────────
--
-- Sets LTM = 1 on spawn, on DescendantAdded, and every Heartbeat to win races
-- against server scripts that reset transparency.

local m1Active   = false
local m1Conns    = {}

local function m1Apply(char)
    eachPart(char, function(p) p.LocalTransparencyModifier = 1 end)
end

local function m1Stop()
    for _, c in ipairs(m1Conns) do c:Disconnect() end
    m1Conns = {}
    eachPart(lp.Character, function(p) p.LocalTransparencyModifier = 0 end)
end

local function m1WireChar(char)
    m1Apply(char)
    m1Conns[#m1Conns + 1] = char.DescendantAdded:Connect(function(d)
        if m1Active and d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
            d.LocalTransparencyModifier = 1
        end
    end)
end

local function m1Start()
    m1WireChar(lp.Character)

    m1Conns[#m1Conns + 1] = lp.CharacterAdded:Connect(function(char)
        if m1Active then m1WireChar(char) end
    end)

    m1Conns[#m1Conns + 1] = RunService.Heartbeat:Connect(function()
        if m1Active then
            m1Apply(lp.Character)
        end
    end)
end

btn1.MouseButton1Click:Connect(function()
    m1Active = not m1Active
    if m1Active then
        m1Start()
        btn1.Text             = "LTM Loop: ON"
        btn1.BackgroundColor3 = Color3.fromRGB(0, 130, 60)
    else
        m1Stop()
        btn1.Text             = "LTM Loop: OFF"
        btn1.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    end
end)

-- ── Method 2 — hookmetamethod __index intercept ───────────────────────────────
--
-- Hooks game's metatable so any read of .LocalTransparencyModifier on the local
-- player's parts (except HRP) returns 1, regardless of what the server writes.
-- Survives property resets because the value is never actually stored.

local m2Active   = false
local m2Hooked   = false
local m2Original = nil

local function isOwnPart(obj)
    if not (typeof(obj) == "Instance" and obj:IsA("BasePart")) then return false end
    if obj.Name == "HumanoidRootPart" then return false end
    local char = lp.Character
    return char ~= nil and obj:IsDescendantOf(char)
end

local function m2Start()
    if m2Hooked then return end
    m2Hooked = true
    local mt  = getrawmetatable(game)
    m2Original = mt.__index
    setreadonly(mt, false)
    mt.__index = newcclosure(function(self, key)
        if key == "LocalTransparencyModifier" and isOwnPart(self) then
            return 1
        end
        return m2Original(self, key)
    end)
    setreadonly(mt, true)
end

local function m2Stop()
    if not m2Hooked then return end
    m2Hooked = false
    local mt = getrawmetatable(game)
    setreadonly(mt, false)
    mt.__index = m2Original
    setreadonly(mt, true)
    m2Original = nil
end

btn2.MouseButton1Click:Connect(function()
    m2Active = not m2Active
    if m2Active then
        m2Start()
        btn2.Text             = "Hook __index: ON"
        btn2.BackgroundColor3 = Color3.fromRGB(0, 90, 175)
    else
        m2Stop()
        btn2.Text             = "Hook __index: OFF"
        btn2.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    end
end)

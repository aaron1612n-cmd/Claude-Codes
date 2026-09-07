-- invisiblescript.client.lua
-- Instantly turns your character invisible. HumanoidRootPart never moves,
-- never loses collision — position/physics stay exactly where they are.
-- Toggle with C or the on-screen button (mobile).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local TOGGLE_KEY = Enum.KeyCode.C

-- ----------------------------------------------------------------

local player = Players.LocalPlayer
local char   = player.Character or player.CharacterAdded:Wait()
local hidden = false

local function setTransparency(model, value)
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            v.LocalTransparencyModifier = value
        elseif v:IsA("Decal") then
            v.LocalTransparencyModifier = value
        end
    end
end

local function refreshTransparency()
    if hidden then
        setTransparency(char, 1)
    end
end

local function showChar()
    hidden = false
    setTransparency(char, 0)
end

local function hideChar()
    hidden = true
    setTransparency(char, 1)
end

local function toggle()
    if hidden then showChar() else hideChar() end
end

-- keep newly-streamed-in accessories/parts invisible while toggled on
char.DescendantAdded:Connect(function()
    task.defer(refreshTransparency)
end)

player.CharacterAdded:Connect(function(newChar)
    char = newChar
    hidden = false
    newChar.DescendantAdded:Connect(function()
        task.defer(refreshTransparency)
    end)
end)

-- keyboard
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == TOGGLE_KEY then toggle() end
end)

-- mobile toggle button
local gui = Instance.new("ScreenGui")
gui.Name = "InvisibleGui"
gui.ResetOnSpawn = false
gui.Parent = player.PlayerGui

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(0, 90, 0, 90)
btn.Position = UDim2.new(1, -110, 1, -120)
btn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
btn.TextColor3 = Color3.fromRGB(255, 255, 255)
btn.Text = "HIDE"
btn.Font = Enum.Font.GothamBold
btn.TextSize = 18
btn.BorderSizePixel = 0
btn.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = btn

btn.MouseButton1Click:Connect(function()
    toggle()
    if hidden then
        btn.Text = "SHOW"
        btn.BackgroundColor3 = Color3.fromRGB(180, 30, 30)
    else
        btn.Text = "HIDE"
        btn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    end
end)

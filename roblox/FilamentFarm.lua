-- FilamentFarm.lua  —  Filament chain farmer with GUI
-- Executor: Delta (Luau)  |  fireproximityprompt required

local Players    = game:GetService("Players")
local TweenSvc   = game:GetService("TweenService")

local LP         = Players.LocalPlayer
local TP_OFFSET  = Vector3.new(0, 3, 0)

-- ── tunables ──────────────────────────────────────────────────────────────────
local CFG = {
    SCAN_DELAY   = 1.2,
    PICKUP_WAIT  = 0.25,
    INTER_WAIT   = 0.35,
    CRAFT_WAIT   = 2.0,
    LOOP_WAIT    = 0.5,
}
-- ──────────────────────────────────────────────────────────────────────────────

-- ═══════════════════════════════════════════════════════════════════════════════
--  GUI
-- ═══════════════════════════════════════════════════════════════════════════════

-- nuke old instance if re-executing
local OLD = game:GetService("CoreGui"):FindFirstChild("FilamentFarmGui")
if OLD then OLD:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name            = "FilamentFarmGui"
SG.ResetOnSpawn    = false
SG.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
pcall(function() SG.Parent = game:GetService("CoreGui") end)
if not SG.Parent then SG.Parent = LP:WaitForChild("PlayerGui") end

-- main frame
local MAIN = Instance.new("Frame", SG)
MAIN.Name            = "Main"
MAIN.Size            = UDim2.new(0, 320, 0, 240)
MAIN.Position        = UDim2.new(0, 20, 0, 100)
MAIN.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
MAIN.BorderSizePixel = 0
Instance.new("UICorner", MAIN).CornerRadius = UDim.new(0, 8)
Instance.new("UIStroke", MAIN).Color = Color3.fromRGB(60, 60, 80)

-- title bar (also drag handle)
local TBAR = Instance.new("Frame", MAIN)
TBAR.Name            = "TitleBar"
TBAR.Size            = UDim2.new(1, 0, 0, 30)
TBAR.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
TBAR.BorderSizePixel = 0
Instance.new("UICorner", TBAR).CornerRadius = UDim.new(0, 8)

local TITLE = Instance.new("TextLabel", TBAR)
TITLE.Size            = UDim2.new(1, -36, 1, 0)
TITLE.Position        = UDim2.new(0, 10, 0, 0)
TITLE.BackgroundTransparency = 1
TITLE.Text            = "FilamentFarm"
TITLE.TextColor3      = Color3.fromRGB(200, 200, 220)
TITLE.Font            = Enum.Font.GothamBold
TITLE.TextSize        = 13
TITLE.TextXAlignment  = Enum.TextXAlignment.Left

-- close button
local CLOSE = Instance.new("TextButton", TBAR)
CLOSE.Size            = UDim2.new(0, 24, 0, 24)
CLOSE.Position        = UDim2.new(1, -28, 0.5, -12)
CLOSE.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CLOSE.Text            = "×"
CLOSE.TextColor3      = Color3.new(1,1,1)
CLOSE.Font            = Enum.Font.GothamBold
CLOSE.TextSize        = 14
CLOSE.BorderSizePixel = 0
Instance.new("UICorner", CLOSE).CornerRadius = UDim.new(0, 4)
CLOSE.MouseButton1Click:Connect(function() SG:Destroy() end)

-- body padding
local BODY = Instance.new("Frame", MAIN)
BODY.Size            = UDim2.new(1, -16, 1, -38)
BODY.Position        = UDim2.new(0, 8, 0, 34)
BODY.BackgroundTransparency = 1

local UIL = Instance.new("UIListLayout", BODY)
UIL.SortOrder    = Enum.SortOrder.LayoutOrder
UIL.Padding      = UDim.new(0, 6)

local function Label(parent, text, order)
    local f = Instance.new("Frame", parent)
    f.Size            = UDim2.new(1, 0, 0, 16)
    f.BackgroundTransparency = 1
    f.LayoutOrder     = order or 0
    local l = Instance.new("TextLabel", f)
    l.Size            = UDim2.new(1, 0, 1, 0)
    l.BackgroundTransparency = 1
    l.Text            = text
    l.TextColor3      = Color3.fromRGB(140, 140, 160)
    l.Font            = Enum.Font.Gotham
    l.TextSize        = 12
    l.TextXAlignment  = Enum.TextXAlignment.Left
    return l
end

-- status row
local STATUS_LBL = Label(BODY, "Status: idle", 1)
STATUS_LBL.TextColor3 = Color3.fromRGB(180, 180, 200)

-- step row
local STEP_LBL = Label(BODY, "Step: —", 2)

-- count row
local COUNT_LBL = Label(BODY, "Filament: 0", 3)
COUNT_LBL.TextColor3 = Color3.fromRGB(120, 220, 140)

-- log box
local LOG_OUTER = Instance.new("Frame", BODY)
LOG_OUTER.Size            = UDim2.new(1, 0, 0, 96)
LOG_OUTER.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
LOG_OUTER.BorderSizePixel = 0
LOG_OUTER.LayoutOrder     = 4
Instance.new("UICorner", LOG_OUTER).CornerRadius = UDim.new(0, 5)

local LOG_SF = Instance.new("ScrollingFrame", LOG_OUTER)
LOG_SF.Size            = UDim2.new(1, -4, 1, -4)
LOG_SF.Position        = UDim2.new(0, 2, 0, 2)
LOG_SF.BackgroundTransparency = 1
LOG_SF.BorderSizePixel = 0
LOG_SF.ScrollBarThickness = 3
LOG_SF.CanvasSize      = UDim2.new(0, 0, 0, 0)
LOG_SF.AutomaticCanvasSize = Enum.AutomaticSize.Y

local LOG_UIL = Instance.new("UIListLayout", LOG_SF)
LOG_UIL.SortOrder = Enum.SortOrder.LayoutOrder
LOG_UIL.Padding   = UDim.new(0, 1)

local logIndex = 0
local function pushLog(msg)
    logIndex = logIndex + 1
    local row = Instance.new("TextLabel", LOG_SF)
    row.Size            = UDim2.new(1, -4, 0, 14)
    row.BackgroundTransparency = 1
    row.Text            = msg
    row.TextColor3      = Color3.fromRGB(100, 200, 120)
    row.Font            = Enum.Font.Code
    row.TextSize        = 11
    row.TextXAlignment  = Enum.TextXAlignment.Left
    row.TextTruncate    = Enum.TextTruncate.AtEnd
    row.LayoutOrder     = logIndex
    -- trim to last 60 lines
    local kids = LOG_SF:GetChildren()
    local excess = 0
    for _, k in ipairs(kids) do
        if k:IsA("TextLabel") then excess = excess + 1 end
    end
    if excess > 60 then
        for _, k in ipairs(kids) do
            if k:IsA("TextLabel") then k:Destroy() break end
        end
    end
    -- auto-scroll
    task.defer(function()
        LOG_SF.CanvasPosition = Vector2.new(0, LOG_SF.AbsoluteCanvasSize.Y)
    end)
end

-- start / stop button
local BTN = Instance.new("TextButton", BODY)
BTN.Size            = UDim2.new(1, 0, 0, 28)
BTN.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
BTN.Text            = "START"
BTN.TextColor3      = Color3.new(1,1,1)
BTN.Font            = Enum.Font.GothamBold
BTN.TextSize        = 13
BTN.BorderSizePixel = 0
BTN.LayoutOrder     = 5
Instance.new("UICorner", BTN).CornerRadius = UDim.new(0, 5)

-- ── drag ─────────────────────────────────────────────────────────────────────
do
    local dragging, dragStart, startPos
    TBAR.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging  = true
            dragStart = i.Position
            startPos  = MAIN.Position
        end
    end)
    TBAR.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    TBAR.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - dragStart
            MAIN.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  Farming logic
-- ═══════════════════════════════════════════════════════════════════════════════

local running    = false
local farmThread = nil
local totalFilament = 0

local function setStatus(s)
    STATUS_LBL.Text = "Status: " .. s
end
local function setStep(s)
    STEP_LBL.Text = "Step: " .. s
end
local function log(fmt, ...)
    local msg = string.format(fmt, ...)
    pushLog(msg)
    print("[FilamentFarm] " .. msg)
end

-- ── inventory helpers ────────────────────────────────────────────────────────

local function getHRP()
    local char = LP.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function countInBackpack(name)
    local n = 0
    for _, v in ipairs(LP.Backpack:GetChildren()) do
        if v.Name == name then n = n + 1 end
    end
    local char = LP.Character
    if char then
        for _, v in ipairs(char:GetChildren()) do
            if v:IsA("Tool") and v.Name == name then n = n + 1 end
        end
    end
    return n
end

local function inBackpack(name)
    return countInBackpack(name) > 0
end

local function firstPrompt(obj)
    for _, d in ipairs(obj:GetDescendants()) do
        if d:IsA("ProximityPrompt") then return d end
    end
end

local function scanDrops(itemName)
    local found = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj.Name == itemName then
            local pr = firstPrompt(obj)
            if pr then
                local ok, piv = pcall(function() return obj:GetPivot() end)
                if ok then
                    found[#found + 1] = { model = obj, prompt = pr, pos = piv.Position }
                end
            end
        end
    end
    return found
end

local function byDist(hrpPos, items)
    table.sort(items, function(a, b)
        return (a.pos - hrpPos).Magnitude < (b.pos - hrpPos).Magnitude
    end)
    return items
end

local function pickup(item)
    local hrp = getHRP()
    if not hrp then return false end
    if not item.model.Parent then return false end
    hrp.CFrame = CFrame.new(item.pos + TP_OFFSET)
    task.wait(CFG.PICKUP_WAIT)
    if not item.prompt.Parent then return false end
    pcall(fireproximityprompt, item.prompt)
    return true
end

-- ── machine helpers ───────────────────────────────────────────────────────────

local _machines = {}
local function getMachine(name)
    if _machines[name] and _machines[name].Parent then
        return _machines[name]
    end
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj.Name == name then
            _machines[name] = obj
            return obj
        end
    end
    return nil
end

local function useMachine(machineName)
    local machine = getMachine(machineName)
    if not machine then
        log("machine %q not found", machineName)
        return false
    end
    local hrp = getHRP()
    if not hrp then return false end
    local ok, piv = pcall(function() return machine:GetPivot() end)
    if not ok then return false end
    hrp.CFrame = CFrame.new(piv.Position + TP_OFFSET)
    task.wait(CFG.PICKUP_WAIT)
    local pr = firstPrompt(machine)
    if not pr then
        log("no prompt on %q", machineName)
        return false
    end
    pcall(fireproximityprompt, pr)
    task.wait(CFG.CRAFT_WAIT)
    return true
end

-- ── gather ───────────────────────────────────────────────────────────────────

local function gatherItem(itemName, need)
    need = need or 1
    while running and countInBackpack(itemName) < need do
        setStep("gather: " .. itemName .. " (" .. countInBackpack(itemName) .. "/" .. need .. ")")
        local hrp = getHRP()
        if not hrp then task.wait(1) end
        if hrp then
            local drops = byDist(hrp.Position, scanDrops(itemName))
            local got = 0
            for _, item in ipairs(drops) do
                if not running then break end
                if countInBackpack(itemName) >= need then break end
                if pickup(item) then
                    got = got + 1
                    log("picked %s (%d/%d)", itemName, countInBackpack(itemName), need)
                    task.wait(CFG.INTER_WAIT)
                end
            end
            if got == 0 then
                log("no %s drops found, waiting…", itemName)
                task.wait(CFG.SCAN_DELAY)
            end
        end
    end
end

-- ── craft ────────────────────────────────────────────────────────────────────

local function craftStandard(output, a, b)
    setStep("craft: " .. a .. " + " .. b .. " → " .. output)
    log("crafting %s + %s → %s", a, b, output)
    local attempts = 0
    while running and not inBackpack(output) do
        attempts = attempts + 1
        if not inBackpack(a) then gatherItem(a, 1) end
        if not inBackpack(b) then gatherItem(b, 1) end
        if not running then break end
        useMachine("Combiner")
        if not inBackpack(output) then
            log("no output yet (attempt %d), retrying…", attempts)
            task.wait(1)
        end
    end
    if inBackpack(output) then log("got %s", output) end
end

local function craftTriple(output, a, b, c)
    setStep("craft: " .. a .. " + " .. b .. " + " .. c .. " → " .. output)
    log("crafting %s + %s + %s → %s", a, b, c, output)
    local attempts = 0
    while running and not inBackpack(output) do
        attempts = attempts + 1
        if not inBackpack(a) then gatherItem(a, 1) end
        if not inBackpack(b) then gatherItem(b, 1) end
        if not inBackpack(c) then gatherItem(c, 1) end
        if not running then break end
        useMachine("Combiner2")
        if not inBackpack(output) then
            log("no output yet (attempt %d), retrying…", attempts)
            task.wait(1)
        end
    end
    if inBackpack(output) then log("got %s", output) end
end

-- ── main farm loop ───────────────────────────────────────────────────────────

local function farmLoop()
    log("farm started")
    setStatus("running")

    while running do
        -- step 1 – raw mats
        setStatus("gathering")
        log("--- new cycle ---")
        gatherItem("Hydrogen",       2)
        gatherItem("Oxygen",         1)
        gatherItem("AmalgamResidue", 1)
        gatherItem("CopperWiring",   1)
        gatherItem("SulphuricAcid",  1)
        gatherItem("PolymerPulp",    1)

        if not running then break end

        -- step 2 – StandardCombiner chain
        setStatus("crafting")
        craftStandard("HydrogenPeroxide",   "Hydrogen",          "Oxygen")
        craftStandard("CompositeAlloyPlate","AmalgamResidue",     "HydrogenPeroxide")

        if not running then break end

        -- step 3 – TripleCombiner chain
        craftTriple("MetallurgicSlop","CompositeAlloyPlate","CopperWiring","SulphuricAcid")
        craftTriple("Filament",       "MetallurgicSlop",   "PolymerPulp", "Hydrogen")

        if not running then break end

        totalFilament = totalFilament + 1
        COUNT_LBL.Text = "Filament: " .. totalFilament
        log("Filament #%d done!", totalFilament)

        task.wait(CFG.LOOP_WAIT)
    end

    setStatus("stopped")
    setStep("—")
    log("farm stopped")
end

-- ── button ───────────────────────────────────────────────────────────────────

BTN.MouseButton1Click:Connect(function()
    if running then
        -- stop
        running = false
        BTN.Text = "START"
        BTN.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
    else
        -- start
        running = true
        BTN.Text = "STOP"
        BTN.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
        farmThread = task.spawn(function()
            local ok, err = pcall(farmLoop)
            if not ok then
                log("ERROR: " .. tostring(err))
                setStatus("error — check log")
                running = false
                BTN.Text = "START"
                BTN.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
            end
        end)
    end
end)

pushLog("FilamentFarm loaded — press START")

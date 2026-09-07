-- UnderSlide.client.lua
-- Hold LEFT_SHIFT to crouch/slide under. Release to stand back up.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local ANIM_ID = "rbxassetid://YOUR_ANIMATION_ID_HERE" -- replace with your anim
local CROUCH_HIP_HEIGHT = 0.5   -- how low the character sinks (default is ~2)
local NORMAL_HIP_HEIGHT = 2.0
local SLIDE_KEY = Enum.KeyCode.LeftShift

-- ----------------------------------------------------------------

local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local humanoid = char:WaitForChild("Humanoid") :: Humanoid
local animator = humanoid:WaitForChild("Animator") :: Animator

local anim = Instance.new("Animation")
anim.AnimationId = ANIM_ID

local track: AnimationTrack = animator:LoadAnimation(anim)
track.Priority = Enum.AnimationPriority.Action
track.Looped = true

local crouching = false

local function enterCrouch()
    if crouching then return end
    crouching = true
    humanoid.HipHeight = CROUCH_HIP_HEIGHT
    if ANIM_ID ~= "rbxassetid://YOUR_ANIMATION_ID_HERE" then
        track:Play(0.15)
    end
end

local function exitCrouch()
    if not crouching then return end
    crouching = false
    humanoid.HipHeight = NORMAL_HIP_HEIGHT
    track:Stop(0.15)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == SLIDE_KEY then
        enterCrouch()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == SLIDE_KEY then
        exitCrouch()
    end
end)

-- clean up on respawn
player.CharacterAdded:Connect(function(newChar)
    char = newChar
    humanoid = newChar:WaitForChild("Humanoid")
    animator = humanoid:WaitForChild("Animator")
    track = animator:LoadAnimation(anim)
    track.Priority = Enum.AnimationPriority.Action
    track.Looped = true
    crouching = false
end)

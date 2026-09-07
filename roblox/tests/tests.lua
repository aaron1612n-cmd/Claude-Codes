step = assert(renderSteps["IpadMouseLock"], "render step never bound")

-- Helpers -------------------------------------------------------------------
local function mouseMove(x, y, dx, dy)
	UserInputService._mouseLoc = Vector2.new(x, y)
	UserInputService.InputChanged.fire({
		UserInputType = Enum.UserInputType.MouseMovement,
		Position = Vector3.new(x, y, 0),
		Delta = Vector3.new(dx or 0, dy or 0, 0),
	}, false)
end
local function key(kc)
	UserInputService.InputBegan.fire({UserInputType = Enum.UserInputType.Keyboard, KeyCode = kc}, false)
end
local function yawOf() return math.deg(math.atan2(-camera.CFrame.LookVector.X, -camera.CFrame.LookVector.Z)) end
local function pitchOf() return math.deg(math.asin(camera.CFrame.LookVector.Y)) end

local function setShiftLockForTest(on)
	-- The script owns shiftLockOn; drive it through the same key path.
	for i = 1, 4 do
		if (camera.CameraType == Enum.CameraType.Scriptable) == on then break end
		key(Enum.KeyCode.LeftShift)
		step(1/60)
	end
end
local function angleDelta(a, b) return (b - a + 540) % 360 - 180 end
local pass, fail = 0, 0
local function check(name, cond, detail)
	if cond then pass += 1; print(("  ok   %s"):format(name))
	else fail += 1; print(("  FAIL %s  -- %s"):format(name, tostring(detail))) end
end

print("== 1. idle in third person: script stays out of the way ==")
step(1/60)
check("camera left on Custom", camera.CameraType == Enum.CameraType.Custom, camera.CameraType)

print("== 2. shift lock toggle takes the camera over ==")
key(Enum.KeyCode.LeftShift)
step(1/60)
check("camera is Scriptable", camera.CameraType == Enum.CameraType.Scriptable, camera.CameraType)
check("AutoRotate disabled", humanoid.AutoRotate == false)

print("== 3. iPad path: cursor moves, Delta is always (0,0) ==")
local yaw0 = yawOf()
mouseMove(600, 400, 0, 0)   -- establishes reference point
step(1/60)
yaw0 = yawOf()
mouseMove(700, 400, 0, 0)   -- 100px right, no native delta
step(1/60)
local yaw1 = yawOf()
check("camera turned from position-delta alone", math.abs(yaw1 - yaw0) > 20, ("%.2f -> %.2f"):format(yaw0, yaw1))
check("turned right (yaw decreases)", yaw1 < yaw0, ("%.2f -> %.2f"):format(yaw0, yaw1))

print("== 4. pitch responds and clamps ==")
local p0 = pitchOf()
mouseMove(700, 300, 0, 0)   -- 100px up
step(1/60)
check("looking up raises pitch", pitchOf() > p0, ("%.2f -> %.2f"):format(p0, pitchOf()))
for i = 1, 40 do mouseMove(700, 300 - i * 50, 0, 0); step(1/60) end
check("pitch clamped at MaxPitch", pitchOf() <= 78.001 and pitchOf() > 77, pitchOf())

print("== 5. edge steering: cursor pinned at the border keeps turning ==")
UserInputService._mouseLoc = Vector2.new(1195, 400)  -- jammed against the right edge
local before = yawOf()
for i = 1, 30 do step(1/60) end   -- half a second with no new input events
local after = yawOf()
check("camera kept turning at the edge", math.abs(angleDelta(before, after)) > 5, ("%.2f -> %.2f"):format(before, after))
check("kept turning right, not left", angleDelta(before, after) < -20, ("%.2f -> %.2f (delta %.2f)"):format(before, after, angleDelta(before, after)))

print("== 6. desktop path: real pointer lock disables edge steering ==")
UserInputService._mouseLoc = Vector2.new(600, 400)
mouseMove(600, 400, 5, 0)   -- native delta, cursor pinned at centre
mouseMove(600, 400, 5, 0)   -- second identical position => lock detected
step(1/60)
UserInputService._mouseLoc = Vector2.new(1195, 400)  -- would normally edge-steer
local lockedYaw = yawOf()
for i = 1, 30 do step(1/60) end
check("no phantom edge spin once truly locked", math.abs(yawOf() - lockedYaw) < 0.001, yawOf() - lockedYaw)

print("== 7. first person hides the local character, third person restores it ==")
UserInputService._mouseLoc = Vector2.new(600, 400)
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel, Position = Vector3.new(0,0,20)}, false)
step(1/60)
check("zoomed into first person", head.LocalTransparencyModifier == 1, head.LocalTransparencyModifier)
check("camera sits at the head", (camera.CFrame.Position - head.Position).Magnitude < 0.01,
	(camera.CFrame.Position - head.Position).Magnitude)
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel, Position = Vector3.new(0,0,-20)}, false)
step(1/60)
check("character visible again in third person", head.LocalTransparencyModifier == 0, head.LocalTransparencyModifier)

print("== 8. releasing shift lock hands the camera back ==")
key(Enum.KeyCode.LeftShift)
step(1/60)
check("camera back to Custom", camera.CameraType == Enum.CameraType.Custom, camera.CameraType)
check("AutoRotate restored", humanoid.AutoRotate == true)
check("cursor restored", UserInputService.MouseIconEnabled == true)
check("character not left invisible", head.LocalTransparencyModifier == 0, head.LocalTransparencyModifier)

print("== 9. camera collision ==")
-- Back to a clean third-person shift lock, zoomed out and fully settled.
key(Enum.KeyCode.LeftShift)
UserInputService._mouseLoc = Vector2.new(600, 400)
step(1/60)
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel,
	Position = Vector3.new(0, 0, -20)}, false)
for i = 1, 200 do step(1/60) end
local openDist = (camera.CFrame.Position - head.Position).Magnitude
check("no wall means full distance", openDist > 5, openDist)

wallDistance = 3
step(1/60)
local walled = (camera.CFrame.Position - head.Position).Magnitude
check("wall pulls the camera in", walled < openDist and walled <= 3.01, walled)
check("camera stops short of the wall", walled <= 3 - 0.25 + 1e-6, walled)

print("== 10. a wall that shoves the camera into you hides the character ==")
wallDistance = 0.4
step(1/60)
check("character hidden when camera is inside it", head.LocalTransparencyModifier == 1,
	head.LocalTransparencyModifier)

print("== 11. easing out: no single-frame pop back to full distance ==")
wallDistance = nil
step(1/60)
local afterOneFrame = (camera.CFrame.Position - head.Position).Magnitude
check("does not snap straight back out", afterOneFrame < openDist * 0.9,
	("%.3f vs open %.3f"):format(afterOneFrame, openDist))
for i = 1, 120 do step(1/60) end
local settled = (camera.CFrame.Position - head.Position).Magnitude
check("but does return to full distance", math.abs(settled - openDist) < 0.05,
	("%.3f vs open %.3f"):format(settled, openDist))
check("character visible again once the camera is back out", head.LocalTransparencyModifier == 0,
	head.LocalTransparencyModifier)

print("== 12. snapping in is immediate, so nothing clips ==")
wallDistance = 1.0
step(1/60)
check("one frame is enough to pull in", (camera.CFrame.Position - head.Position).Magnitude <= 1.0,
	(camera.CFrame.Position - head.Position).Magnitude)
wallDistance = nil

print("== 13. shift lock side offset is collision tested, not bolted on ==")
-- With the camera hard against a wall the side offset must be swept too, so
-- the camera cannot end up further from the player than the wall allows.
wallDistance = 0.5
for i = 1, 10 do step(1/60) end
check("side offset cannot push past the wall",
	(camera.CFrame.Position - head.Position).Magnitude <= 0.51,
	(camera.CFrame.Position - head.Position).Magnitude)
wallDistance = nil
for i = 1, 120 do step(1/60) end

print("== 14. a game that caps zoom is respected ==")
flushDelays()
player.CameraMinZoomDistance = 0.5
player.CameraMaxZoomDistance = 6
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel,
	Position = Vector3.new(0, 0, -50)}, false)
for i = 1, 200 do step(1/60) end
-- The cap applies to zoom distance; the shift lock side offset sits on top of
-- it, exactly as it does for Roblox's own camera. sqrt(6^2 + 1.75^2) = 6.25.
local capped = (camera.CFrame.Position - head.Position).Magnitude
check("cannot zoom past the game's maximum", capped <= 6.26, capped)
check("and the cap actually bit", capped < 7, capped)
player.CameraMaxZoomDistance = 400

print("== 15. a game that forbids first person is respected ==")
player.CameraMinZoomDistance = 8
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel,
	Position = Vector3.new(0, 0, 50)}, false)
for i = 1, 200 do step(1/60) end
check("cannot zoom inside the game's minimum",
	(camera.CFrame.Position - head.Position).Magnitude >= 7.9,
	(camera.CFrame.Position - head.Position).Magnitude)
check("character stays visible, not hidden by a forced-in camera",
	head.LocalTransparencyModifier == 0, head.LocalTransparencyModifier)
player.CameraMinZoomDistance = 0.5

print("== 16. scroll aimed at game UI does not zoom ==")
for i = 1, 200 do step(1/60) end
local beforeScroll = (camera.CFrame.Position - head.Position).Magnitude
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel,
	Position = Vector3.new(0, 0, 5)}, true)   -- gameProcessed
for i = 1, 60 do step(1/60) end
check("gameProcessed scroll ignored",
	math.abs((camera.CFrame.Position - head.Position).Magnitude - beforeScroll) < 0.01,
	(camera.CFrame.Position - head.Position).Magnitude)

print("== 17. pointer warps do not fling the camera ==")
mouseMove(600, 400, 0, 0)
step(1/60)
local steadyYaw = yawOf()
mouseMove(150, 400, 0, 0)  -- a 450px jump: pointer snapping, not a real movement
step(1/60)
check("large cursor jump ignored", math.abs(angleDelta(steadyYaw, yawOf())) < 1,
	("%.2f -> %.2f"):format(steadyYaw, yawOf()))
mouseMove(190, 400, 0, 0)  -- a normal 40px move from the new spot still works
step(1/60)
check("a normal move still turns the camera", math.abs(angleDelta(steadyYaw, yawOf())) > 5,
	("%.2f -> %.2f"):format(steadyYaw, yawOf()))

print("== 18. seated characters are not force-turned ==")
UserInputService._mouseLoc = Vector2.new(600, 400)
mouseMove(600, 400, 0, 0)
step(1/60)
humanoid.Sit = true
humanoid._state = Enum.HumanoidStateType.Seated
local seatedCFrame = root.CFrame
mouseMove(750, 400, 0, 0)
step(1/60)
check("root part left alone while seated", root.CFrame == seatedCFrame)
check("camera still turns while seated", math.abs(angleDelta(steadyYaw, yawOf())) > 0)
humanoid.Sit = false
humanoid._state = Enum.HumanoidStateType.Running
mouseMove(750, 400, 0, 0)
step(1/60)
check("root part turns again once standing", root.CFrame ~= seatedCFrame)

print("== 19. death hands the camera back ==")
humanoid.Health = 0
step(1/60)
check("camera released on death", camera.CameraType == Enum.CameraType.Custom, camera.CameraType)
check("character not left invisible on death", head.LocalTransparencyModifier == 0,
	head.LocalTransparencyModifier)
humanoid.Health = 100

print("== 20. handing back syncs zoom so you can leave first person ==")
-- Zoom to first person, then back out. Roblox keeps its own zoom, so without
-- the nudge the stock camera would drag the player straight back in.
flushDelays()
player.CameraMinZoomDistance = 0.5
step(1/60)                    -- alive again, so shift lock shows in the camera type
setShiftLockForTest(false)
flushDelays()
player.CameraMinZoomDistance = 0.5
camera.CFrame = CFrame.new(Vector3.new(0, 5, 0.4))   -- stock camera in first person
step(1/60)
check("first person engages from the stock camera", camera.CameraType == Enum.CameraType.Scriptable,
	camera.CameraType)
UserInputService.InputChanged.fire({UserInputType = Enum.UserInputType.MouseWheel,
	Position = Vector3.new(0, 0, -4)}, false)   -- scroll out
step(1/60)
check("released back to the stock camera", camera.CameraType == Enum.CameraType.Custom,
	camera.CameraType)
check("stock camera pushed out so it will not snap back in",
	player.CameraMinZoomDistance > 1, player.CameraMinZoomDistance)
flushDelays()
check("the player's own zoom limit is restored afterwards",
	player.CameraMinZoomDistance == 0.5, player.CameraMinZoomDistance)

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then error("test failures: " .. fail, 0) end

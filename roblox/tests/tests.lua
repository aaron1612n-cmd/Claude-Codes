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

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then error("test failures: " .. fail, 0) end

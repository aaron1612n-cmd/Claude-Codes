--[[
	IpadMouseLock — pointer-lock camera for Roblox on iPadOS

	Why this exists
	---------------
	iPadOS never hands Roblox a real locked pointer. `MouseBehavior = LockCenter`
	is a no-op there, so `InputObject.Delta` stays at (0, 0) and the stock camera
	gets nothing to work with: shift lock and first person leave the camera stuck
	while the cursor slides around the screen.

	What this does
	--------------
	Takes the camera over (CameraType = Scriptable) whenever you are in first
	person or shift lock, and drives yaw/pitch itself:

	  * Uses the native mouse Delta when the platform actually provides one
	    (desktop), and falls back to frame-to-frame cursor *position* deltas when
	    it does not (iPad).
	  * Because the OS cursor stops dead at the screen border, turning would
	    otherwise cap out at one screen-width. When the pointer is not genuinely
	    locked, pushing it into the edge margin adds continuous rotation in that
	    direction, so you can keep turning forever.
	  * Touch drags rotate the camera too, so a finger still works while the
	    script owns the camera.

	Install
	-------
	Drop this in StarterPlayer > StarterPlayerScripts as a LocalScript.
	(Any client-side Luau context works; it only needs to run on the client.)

	Toggle shift lock with Shift, or the on-screen LOCK button if you have no
	keyboard. First person engages automatically when you zoom all the way in.
	Everything worth changing lives in CONFIG below.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CONFIG = {
	-- Degrees of rotation per pixel of pointer movement.
	Sensitivity = 0.32,
	TouchSensitivity = 0.45,
	InvertY = false,

	-- How far you can look up / down, in degrees.
	MinPitch = -78,
	MaxPitch = 78,

	-- Edge steering: only used when the pointer is not really locked (iPad).
	-- Pushing the cursor into this many pixels of the border keeps turning.
	EdgeMargin = 110,
	EdgeTurnSpeed = 1100, -- pixel-equivalents per second at full push

	-- Shift lock: camera sits this far to the player's right, character faces
	-- wherever the camera looks.
	ShiftLockOffset = Vector3.new(1.75, 0, 0),
	ShiftLockKeys = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift },
	ShowToggleButton = true,

	-- Zoom. Anything below FirstPersonDistance counts as first person.
	FirstPersonDistance = 0.75,
	MinZoom = 0.5,
	MaxZoom = 20,
	ZoomStep = 1.5,

	CameraCollision = true, -- pull the camera in so walls don't clip through
	CameraCollisionRadius = 0.5, -- swept sphere, so corners don't slip past
	CameraCollisionPadding = 0.25, -- gap left between camera and wall
	CameraReturnSpeed = 6, -- how fast the camera eases back out, per second

	-- Hide the local character once the camera is this close to it, however it
	-- got that close.
	HideCharacterDistance = 1.5,

	HideCursor = true,
	ShowCrosshair = true, -- fixed aim point; the iPad cursor can't be pinned
}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Camera state -------------------------------------------------------------

local yaw, pitch = 0, 0
local distance = 12
local active = false
local shiftLockOn = false

-- Pointer state ------------------------------------------------------------

local pendingDelta = Vector2.zero
local lastPointerPos = nil
local pointerTrulyLocked = false -- native lock works (desktop); skip edge steering
local activeTouch = nil
local lastTouchPos = nil
local smoothedReach = nil
local sawMouse = false
local lastMouseTime = 0
local lastTouchTime = 0

local refreshToggleButton = function() end -- replaced below if the button exists
local setCrosshairVisible = function() end -- ditto

local function setShiftLock(value)
	shiftLockOn = value
	refreshToggleButton()
end

local function clamp(n, lo, hi)
	return math.max(lo, math.min(hi, n))
end

local function getHumanoid()
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getRootPart()
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

-- Where the camera should orbit around.
local function getFocusPosition()
	local subject = camera.CameraSubject
	if subject and subject:IsA("Humanoid") then
		local character = subject.Parent
		local head = character and character:FindFirstChild("Head")
		if head then
			return head.Position, subject.CameraOffset
		end
		if subject.RootPart then
			return subject.RootPart.Position + Vector3.new(0, 1.5, 0), subject.CameraOffset
		end
	elseif subject and subject:IsA("BasePart") then
		return subject.Position, Vector3.zero
	end
	return camera.CFrame.Position, Vector3.zero
end

-- Distance between the live camera and its subject, used to notice that the
-- stock camera is already in first person before we take over.
local function currentStockDistance()
	local focus = getFocusPosition()
	return (camera.CFrame.Position - focus).Magnitude
end

local function shouldBeActive()
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end
	if shiftLockOn then
		return true
	end
	if active then
		-- We own the camera, so our own zoom decides.
		return distance <= CONFIG.FirstPersonDistance
	end
	return currentStockDistance() <= 1
end

-- Local character visibility -----------------------------------------------
-- We own the camera, so Roblox's own first-person transparency handling can no
-- longer be relied on. Hide the local character ourselves when the camera is
-- inside it. LocalTransparencyModifier is client-render only, so other players
-- still see the character normally.

local hideableParts = {}
local characterHidden = false

local function rebuildHideableParts()
	table.clear(hideableParts)
	local character = player.Character
	if not character then
		return
	end
	for _, item in ipairs(character:GetDescendants()) do
		if (item:IsA("BasePart") or item:IsA("Decal")) and not item:FindFirstAncestorWhichIsA("Tool") then
			table.insert(hideableParts, item)
		end
	end
end

local function setCharacterHidden(hidden)
	local modifier = hidden and 1 or 0
	for index = #hideableParts, 1, -1 do
		local item = hideableParts[index]
		if item.Parent then
			-- Re-applied every frame: the stock transparency controller may still
			-- be running and will otherwise reset this.
			item.LocalTransparencyModifier = modifier
		else
			table.remove(hideableParts, index)
		end
	end
	characterHidden = hidden
end

-- Activation ---------------------------------------------------------------

local function seedFromStockCamera()
	local look = camera.CFrame.LookVector
	yaw = math.deg(math.atan2(-look.X, -look.Z))
	pitch = clamp(math.deg(math.asin(clamp(look.Y, -1, 1))), CONFIG.MinPitch, CONFIG.MaxPitch)

	local d = currentStockDistance()
	if d > 0.1 and d < CONFIG.MaxZoom * 2 then
		distance = clamp(d, CONFIG.MinZoom, CONFIG.MaxZoom)
	end
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		distance = CONFIG.MinZoom
	end
end

local function setActive(on)
	if on == active then
		return
	end
	active = on

	setCrosshairVisible(on)

	if on then
		seedFromStockCamera()
		smoothedReach = nil
		camera.CameraType = Enum.CameraType.Scriptable
		if CONFIG.HideCursor then
			UserInputService.MouseIconEnabled = false
		end
		-- Harmless on iPad, gives a real lock on desktop.
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	else
		camera.CameraType = Enum.CameraType.Custom
		UserInputService.MouseIconEnabled = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default

		local humanoid = getHumanoid()
		if humanoid then
			humanoid.AutoRotate = true
		end
		if characterHidden then
			setCharacterHidden(false)
		end

		pointerTrulyLocked = false
		lastPointerPos = nil
		pendingDelta = Vector2.zero
		activeTouch = nil
		lastTouchPos = nil
	end
end

-- Input --------------------------------------------------------------------

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local delta = Vector2.new(input.Delta.X, input.Delta.Y)

		if delta.Magnitude > 0 then
			pendingDelta += delta
			-- A real pointer lock reports movement while the cursor never moves.
			if active and lastPointerPos and (pos - lastPointerPos).Magnitude < 0.01 then
				pointerTrulyLocked = true
			end
		elseif lastPointerPos then
			-- iPad path: no delta, so derive one from where the cursor went.
			pendingDelta += (pos - lastPointerPos)
		end

		lastPointerPos = pos
		sawMouse = true
		lastMouseTime = os.clock()
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		if active then
			distance = clamp(distance - input.Position.Z * CONFIG.ZoomStep, CONFIG.MinZoom, CONFIG.MaxZoom)
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if active and activeTouch == input and lastTouchPos then
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			pendingDelta += (pos - lastTouchPos) * (CONFIG.TouchSensitivity / CONFIG.Sensitivity)
			lastTouchPos = pos
			lastTouchTime = os.clock()
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.UserInputType == Enum.UserInputType.Touch then
		if active and not gameProcessed and not activeTouch then
			activeTouch = input
			lastTouchPos = Vector2.new(input.Position.X, input.Position.Y)
			lastTouchTime = os.clock()
		end
		return
	end

	if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	for _, key in ipairs(CONFIG.ShiftLockKeys) do
		if input.KeyCode == key then
			setShiftLock(not shiftLockOn)
			break
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == activeTouch then
		activeTouch = nil
		lastTouchPos = nil
	end
end)

-- Pointer movement for this frame, in pixels.
local function takeDelta(dt)
	local delta = pendingDelta
	pendingDelta = Vector2.zero

	-- Edge steering is a mouse-only workaround: skip it when there is no mouse,
	-- when the native lock works, or when the player is currently using touch
	-- (a cursor parked in the margin must not spin the camera under a finger).
	if pointerTrulyLocked or not sawMouse or activeTouch or lastTouchTime > lastMouseTime then
		return delta
	end

	-- The OS cursor is pinned inside the screen, so turning would stop at the
	-- border. Treat the margin as a steering zone instead.
	local pointer = UserInputService:GetMouseLocation()
	local viewport = camera.ViewportSize
	local margin = CONFIG.EdgeMargin
	local push = Vector2.zero

	if pointer.X < margin then
		push += Vector2.new(-(margin - pointer.X) / margin, 0)
	elseif pointer.X > viewport.X - margin then
		push += Vector2.new((pointer.X - (viewport.X - margin)) / margin, 0)
	end
	if pointer.Y < margin then
		push += Vector2.new(0, -(margin - pointer.Y) / margin)
	elseif pointer.Y > viewport.Y - margin then
		push += Vector2.new(0, (pointer.Y - (viewport.Y - margin)) / margin)
	end

	if push.Magnitude > 0 then
		push = Vector2.new(clamp(push.X, -1, 1), clamp(push.Y, -1, 1))
		delta += push * CONFIG.EdgeTurnSpeed * dt
	end

	return delta
end

-- Camera -------------------------------------------------------------------

local collisionParams = RaycastParams.new()
collisionParams.FilterType = Enum.RaycastFilterType.Exclude
collisionParams.IgnoreWater = true
-- Without this, decorative parts and invisible trigger volumes shove the
-- camera around exactly as if they were walls.
collisionParams.RespectCanCollide = true

-- How far the camera can sit along `offset` from `origin` before it would end
-- up inside something. `origin` is always the subject, which sits inside the
-- character we filter out, so the cast never starts inside its own geometry.
local function resolveCollision(origin, offset)
	local reach = offset.Magnitude
	if not CONFIG.CameraCollision or reach < 1e-4 then
		return reach
	end

	local character = player.Character
	collisionParams.FilterDescendantsInstances = character and { character } or {}

	-- A swept sphere stops the camera slipping through corners and doorframes
	-- the way a single thin ray does.
	local hit
	if workspace.Spherecast then
		hit = workspace:Spherecast(origin, CONFIG.CameraCollisionRadius, offset, collisionParams)
	else
		hit = workspace:Raycast(origin, offset, collisionParams)
	end
	if not hit then
		return reach
	end
	return clamp(hit.Distance - CONFIG.CameraCollisionPadding, 0, reach)
end

local function updateCamera(dt)
	if not shouldBeActive() then
		setActive(false)
		return
	end
	setActive(true)

	local delta = takeDelta(dt)
	yaw -= delta.X * CONFIG.Sensitivity
	pitch = clamp(
		pitch + delta.Y * CONFIG.Sensitivity * (CONFIG.InvertY and 1 or -1),
		CONFIG.MinPitch,
		CONFIG.MaxPitch
	)
	yaw = (yaw + 180) % 360 - 180

	-- Keep re-asserting these: the stock camera module and shift lock both
	-- like to put them back.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	if CONFIG.HideCursor then
		UserInputService.MouseIconEnabled = false
	end

	local rotation = CFrame.fromEulerAnglesYXZ(math.rad(pitch), math.rad(yaw), 0)
	local subjectPos, subjectOffset = getFocusPosition()
	local origin = subjectPos + rotation:VectorToWorldSpace(subjectOffset)

	local firstPerson = distance <= CONFIG.FirstPersonDistance

	-- Place the camera with one offset in camera space (+X right, +Z back)
	-- rather than a side offset bolted on after the fact. The shift lock side
	-- offset then gets swept for collision along with the distance, instead of
	-- being free to push the camera through a wall on its own.
	local offset = firstPerson and Vector3.zero
		or Vector3.new(CONFIG.ShiftLockOffset.X, CONFIG.ShiftLockOffset.Y, distance)
	local worldOffset = rotation:VectorToWorldSpace(offset)
	local target = resolveCollision(origin, worldOffset)

	-- Snap inward so nothing ever clips, but ease back out. Grazing the edge of
	-- a wall flickers the cast between hit and miss, and without the easing that
	-- flicker becomes the camera slamming in and out every frame.
	if smoothedReach == nil or target < smoothedReach then
		smoothedReach = target
	else
		smoothedReach += (target - smoothedReach) * math.min(1, dt * CONFIG.CameraReturnSpeed)
	end

	local cameraPos = origin
	if worldOffset.Magnitude > 1e-4 then
		cameraPos = origin + worldOffset.Unit * smoothedReach
	end
	camera.CFrame = CFrame.new(cameraPos) * rotation

	-- Hide the character based on where the camera actually ended up, not on the
	-- zoom we asked for. A wall can shove a third person camera inside your own
	-- head, and keying this off the requested distance left you staring at the
	-- inside of it.
	setCharacterHidden((cameraPos - subjectPos).Magnitude <= CONFIG.HideCharacterDistance)

	-- Shift lock / first person: the character faces where you look.
	local humanoid = getHumanoid()
	local root = getRootPart()
	if humanoid and root then
		humanoid.AutoRotate = false
		local flat = Vector3.new(rotation.LookVector.X, 0, rotation.LookVector.Z)
		if flat.Magnitude > 1e-4 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
		end
	end
end

RunService:BindToRenderStep("IpadMouseLock", Enum.RenderPriority.Camera.Value + 1, updateCamera)

-- Character respawn --------------------------------------------------------

local function watchCharacter(character)
	rebuildHideableParts()
	character.DescendantAdded:Connect(function(item)
		if (item:IsA("BasePart") or item:IsA("Decal")) and not item:FindFirstAncestorWhichIsA("Tool") then
			table.insert(hideableParts, item)
		end
	end)
end

player.CharacterAdded:Connect(function(character)
	setActive(false)
	distance = math.max(distance, CONFIG.MinZoom)
	characterHidden = false
	watchCharacter(character)
end)

if player.Character then
	watchCharacter(player.Character)
end

-- On-screen UI --------------------------------------------------------------
-- iPads often have no Shift key, so give shift lock a tappable control.

if CONFIG.ShowToggleButton or CONFIG.ShowCrosshair then
	local gui = Instance.new("ScreenGui")
	gui.Name = "IpadMouseLockUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	if CONFIG.ShowCrosshair then
		-- iPadOS owns the system pointer, so no script can pin it to the middle
		-- of the screen. A fixed reticle at least gives you a stable aim point
		-- while the cursor wanders off on its own.
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(6, 6)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		dot.BackgroundTransparency = 0.3
		dot.BorderSizePixel = 0
		dot.Visible = false
		dot.Parent = gui

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local dotStroke = Instance.new("UIStroke")
		dotStroke.Color = Color3.fromRGB(0, 0, 0)
		dotStroke.Transparency = 0.5
		dotStroke.Thickness = 1
		dotStroke.Parent = dot

		setCrosshairVisible = function(visible)
			dot.Visible = visible
		end
		setCrosshairVisible(active)
	end

	if not CONFIG.ShowToggleButton then
		return
	end

	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(96, 44)
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -18, 1, -18)
	button.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	button.BackgroundTransparency = 0.25
	button.TextColor3 = Color3.fromRGB(235, 235, 240)
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 14
	button.Text = "LOCK OFF"
	button.AutoButtonColor = false
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 120, 130)
	stroke.Transparency = 0.4
	stroke.Parent = button

	refreshToggleButton = function()
		if shiftLockOn then
			button.Text = "LOCK ON"
			button.TextColor3 = Color3.fromRGB(120, 235, 150)
			stroke.Color = Color3.fromRGB(120, 235, 150)
		else
			button.Text = "LOCK OFF"
			button.TextColor3 = Color3.fromRGB(235, 235, 240)
			stroke.Color = Color3.fromRGB(120, 120, 130)
		end
	end

	button.Activated:Connect(function()
		setShiftLock(not shiftLockOn)
	end)

	refreshToggleButton()
end

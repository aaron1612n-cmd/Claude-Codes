-- Services ------------------------------------------------------------------
renderSteps = {}
RunService = {
	RenderStepped = signal(),
	BindToRenderStep = function(_, name, prio, fn) renderSteps[name] = fn end,
}
UserInputService = {
	InputChanged = signal(), InputBegan = signal(), InputEnded = signal(),
	MouseIconEnabled = true, MouseBehavior = Enum.MouseBehavior.Default,
	_mouseLoc = Vector2.new(600, 400),
}
function UserInputService:GetMouseLocation() return self._mouseLoc end

head = newInstance("Part"); head.ClassName = "BasePart"; head.Name = "Head"
head.Position = Vector3.new(0, 5, 0); head.LocalTransparencyModifier = 0
root = newInstance("Part"); root.ClassName = "BasePart"; root.Name = "HumanoidRootPart"
root.Position = Vector3.new(0, 3.5, 0); root.CFrame = CFrame.new(root.Position)
root.LocalTransparencyModifier = 0
humanoid = newInstance("Humanoid")
humanoid.CameraOffset = Vector3.new(0,0,0); humanoid.AutoRotate = true; humanoid.RootPart = root
character = newInstance("Model")
character._children = {Head = head, HumanoidRootPart = root, Humanoid = humanoid}
humanoid.Parent = character; head.Parent = character; root.Parent = character

camera = {
	CameraType = Enum.CameraType.Custom,
	CameraSubject = humanoid,
	ViewportSize = Vector2.new(1200, 800),
	CFrame = CFrame.new(Vector3.new(0, 5, 12)),
}
playerGui = newInstance("PlayerGui")
player = {
	Character = character, CameraMode = Enum.CameraMode.Classic,
	CharacterAdded = signal(), _children = {PlayerGui = playerGui},
}
function player:WaitForChild(n) return self._children[n] end

-- Tests set `wallDistance` to place a flat obstruction that many studs behind
-- the camera origin; nil means open space.
wallDistance = nil
workspace = {
	CurrentCamera = camera,
	Raycast = function(_, origin, direction, params)
		if not wallDistance then return nil end
		local reach = direction.Magnitude
		if wallDistance > reach then return nil end
		return {Distance = wallDistance, Position = origin + direction.Unit * wallDistance}
	end,
}
RaycastParams = {new = function() return {} end}
local services = {Players = {LocalPlayer = player}, RunService = RunService, UserInputService = UserInputService}
game = {GetService = function(_, n) return assert(services[n], "missing service " .. n) end}

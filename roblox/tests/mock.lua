-- Minimal Roblox runtime stub: enough of the API surface for IpadMouseLock.

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- Vector2 -------------------------------------------------------------------
local V2 = {}
V2.__index = V2
local function v2(x, y) return setmetatable({X = x, Y = y}, V2) end
V2.__add = function(a, b) return v2(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return v2(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b)
	if type(b) == "number" then return v2(a.X * b, a.Y * b) end
	if type(a) == "number" then return v2(b.X * a, b.Y * a) end
	return v2(a.X * b.X, a.Y * b.Y)
end
V2.__index = function(t, k)
	if k == "Magnitude" then return math.sqrt(rawget(t, "X")^2 + rawget(t, "Y")^2) end
	return rawget(V2, k)
end
Vector2 = {new = v2, zero = v2(0, 0)}

-- Vector3 -------------------------------------------------------------------
local V3 = {}
local function v3(x, y, z) return setmetatable({X = x or 0, Y = y or 0, Z = z or 0}, V3) end
V3.__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	if type(a) == "number" then return v3(b.X * a, b.Y * a, b.Z * a) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__index = function(t, k)
	if k == "Magnitude" then return math.sqrt(rawget(t,"X")^2 + rawget(t,"Y")^2 + rawget(t,"Z")^2) end
	if k == "Unit" then local m = t.Magnitude; return v3(t.X/m, t.Y/m, t.Z/m) end
	return nil
end
Vector3 = {new = v3, zero = v3(0,0,0)}

-- CFrame: position + row-major 3x3 rotation ---------------------------------
local CF = {}
local function cf(pos, r)
	return setmetatable({p = pos, r = r or {1,0,0, 0,1,0, 0,0,1}}, CF)
end
local function matmul(a, b)
	local out = {}
	for i = 0, 2 do for j = 0, 2 do
		local s = 0
		for k = 0, 2 do s = s + a[i*3+k+1] * b[k*3+j+1] end
		out[i*3+j+1] = s
	end end
	return out
end
local function matvec(m, v)
	return v3(m[1]*v.X + m[2]*v.Y + m[3]*v.Z,
	          m[4]*v.X + m[5]*v.Y + m[6]*v.Z,
	          m[7]*v.X + m[8]*v.Y + m[9]*v.Z)
end
CF.__mul = function(a, b) return cf(a.p + matvec(a.r, b.p), matmul(a.r, b.r)) end
CF.__index = function(t, k)
	if k == "Position" then return rawget(t, "p") end
	if k == "LookVector" then local m = rawget(t, "r"); return v3(-m[3], -m[6], -m[9]) end
	if k == "VectorToWorldSpace" then
		return function(self, v) return matvec(rawget(self, "r"), v) end
	end
	return nil
end
CFrame = {}
function CFrame.new(pos) return cf(pos) end
function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local Ry = {cy,0,sy, 0,1,0, -sy,0,cy}
	local Rx = {1,0,0, 0,cx,-sx, 0,sx,cx}
	local Rz = {cz,-sz,0, sz,cz,0, 0,0,1}
	return cf(v3(0,0,0), matmul(matmul(Ry, Rx), Rz))
end
function CFrame.lookAt(from, to)
	local f = (to - from).Unit
	local up = v3(0,1,0)
	local rgt = v3(f.Y*up.Z - f.Z*up.Y, f.Z*up.X - f.X*up.Z, f.X*up.Y - f.Y*up.X).Unit
	local u = v3(rgt.Y*f.Z - rgt.Z*f.Y, rgt.Z*f.X - rgt.X*f.Z, rgt.X*f.Y - rgt.Y*f.X)
	local b = -f
	return cf(from, {rgt.X, u.X, b.X, rgt.Y, u.Y, b.Y, rgt.Z, u.Z, b.Z})
end

Color3 = {fromRGB = function(r,g,b) return {R=r,G=g,B=b} end}
UDim = {new = function(s,o) return {Scale=s,Offset=o} end}
UDim2 = {new = function(a,b,c,d) return {} end, fromOffset = function(a,b) return {} end}

-- Enums: any dotted path resolves to a unique sentinel ----------------------
local function enumNode(path)
	return setmetatable({__path = path}, {__index = function(t, k)
		local child = enumNode(path .. "." .. k)
		rawset(t, k, child)
		return child
	end, __tostring = function(t) return path end})
end
Enum = enumNode("Enum")
Enum.RenderPriority.Camera.Value = 200

-- Signals -------------------------------------------------------------------
function signal()
	local handlers = {}
	return {
		Connect = function(_, fn) table.insert(handlers, fn); return {Disconnect = function() end} end,
		fire = function(...) for _, fn in ipairs(handlers) do fn(...) end end,
	}
end

-- Instances -----------------------------------------------------------------
function newInstance(class)
	local inst = {ClassName = class, Name = class, Parent = nil, _children = {}}
	inst.Activated = signal()
	inst.DescendantAdded = signal()
	function inst:IsA(c) return self.ClassName == c end
	function inst:FindFirstChild(n) return self._children[n] end
	function inst:FindFirstChildOfClass(c)
		for _, ch in pairs(self._children) do if ch.ClassName == c then return ch end end
		return nil
	end
	function inst:FindFirstAncestorWhichIsA() return nil end
	function inst:GetDescendants()
		local out = {}
		for _, ch in pairs(self._children) do table.insert(out, ch) end
		return out
	end
	function inst:WaitForChild(n) return self._children[n] end
	return inst
end
Instance = {new = newInstance}

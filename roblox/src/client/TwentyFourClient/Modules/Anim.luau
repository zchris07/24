--[[
	Anim — frame-driven tweens with real CSS cubic-bezier curves, so every
	motion in the web version (deal flight, FLIP moves, pop-ins, the nudge)
	keeps its exact timing and feel.
]]

local RunService = game:GetService("RunService")

local Anim = {}

-- CSS cubic-bezier(x1, y1, x2, y2)
function Anim.bezier(x1: number, y1: number, x2: number, y2: number)
	local function sample(a1, a2, t)
		local it = 1 - t
		return 3 * it * it * t * a1 + 3 * it * t * t * a2 + t * t * t
	end
	local function slope(a1, a2, t)
		local it = 1 - t
		return 3 * it * it * a1 + 6 * it * t * (a2 - a1) + 3 * t * t * (1 - a2)
	end
	return function(x: number): number
		if x <= 0 then
			return 0
		end
		if x >= 1 then
			return 1
		end
		-- Newton, then bisection fallback
		local t = x
		for _ = 1, 8 do
			local err = sample(x1, x2, t) - x
			if math.abs(err) < 1e-5 then
				return sample(y1, y2, t)
			end
			local d = slope(x1, x2, t)
			if math.abs(d) < 1e-6 then
				break
			end
			t -= err / d
		end
		local lo, hi = 0, 1
		t = x
		for _ = 1, 30 do
			local v = sample(x1, x2, t)
			if math.abs(v - x) < 1e-5 then
				break
			end
			if v < x then
				lo = t
			else
				hi = t
			end
			t = (lo + hi) / 2
		end
		return sample(y1, y2, t)
	end
end

Anim.EASE = Anim.bezier(0.22, 0.85, 0.28, 1) -- --ease
Anim.DEAL = Anim.bezier(0.16, 0.79, 0.28, 1)
Anim.CSS_EASE = Anim.bezier(0.25, 0.1, 0.25, 1) -- the "ease" keyword
Anim.LINEAR = function(x: number): number
	return math.clamp(x, 0, 1)
end

local active = {}
local conn: RBXScriptConnection? = nil

local function step()
	local t = os.clock()
	local i = 1
	while i <= #active do
		local a = active[i]
		if a.cancelled then
			table.remove(active, i)
		elseif t >= a.start then
			local p = if a.duration <= 0 then 1 else math.clamp((t - a.start) / a.duration, 0, 1)
			local ok, err = pcall(a.update, a.ease(p), p)
			if not ok then
				warn("[24] anim:", err)
			end
			if p >= 1 then
				table.remove(active, i)
				a.finished = true
				if a.done then
					task.spawn(a.done)
				end
			else
				i += 1
			end
		else
			i += 1
		end
	end
	if #active == 0 and conn then
		conn:Disconnect()
		conn = nil
	end
end

export type Handle = { Cancel: (self: Handle) -> (), cancelled: boolean, finished: boolean }

local HandleMeta = {}
HandleMeta.__index = HandleMeta
function HandleMeta:Cancel()
	self.cancelled = true
end

--[[
	Anim.run(duration, ease, update(e, p), done?, delay?)
	update receives the eased progress e and the raw progress p.
]]
function Anim.run(duration: number, ease, update, done, delay: number?)
	local a = setmetatable({
		start = os.clock() + (delay or 0),
		duration = duration,
		ease = ease or Anim.LINEAR,
		update = update,
		done = done,
		cancelled = false,
		finished = false,
	}, HandleMeta)
	if (delay or 0) <= 0 then
		-- apply the first frame immediately so nothing flashes
		local ok = pcall(update, a.ease(0), 0)
		if not ok then
			a.cancelled = true
		end
	end
	table.insert(active, a)
	if not conn then
		conn = RunService.RenderStepped:Connect(step)
	end
	return a
end

-- keyframe helper: frames = { {0, v}, {0.28, v}, ... } (linear between stops)
function Anim.keyframes(frames, p: number): number
	if p <= frames[1][1] then
		return frames[1][2]
	end
	for i = 2, #frames do
		local a, b = frames[i - 1], frames[i]
		if p <= b[1] then
			local f = (p - a[1]) / math.max(1e-6, b[1] - a[1])
			return a[2] + (b[2] - a[2]) * f
		end
	end
	return frames[#frames][2]
end

function Anim.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Anim.wait(seconds: number)
	task.wait(seconds)
end

return Anim

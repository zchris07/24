--[[
	Ui — the card-table identity (royal blue, flat bone card stock) rebuilt
	from Roblox primitives, plus small helpers the game screen is built from.

	Georgia -> Merriweather (headings, numerals, operators, card ranks)
	Space Grotesk -> Builder Sans (everything read fast)
	Glyphs Roblox fonts lack (suits, check, cross, chevrons) are drawn.
]]

local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local Anim = require(script.Parent:WaitForChild("Anim"))

local Ui = {}

local function setProp(inst: any, k: string, v: any)
	inst[k] = v
end

---------------------------------------------------------------------------
-- palette
---------------------------------------------------------------------------
local function hex(s: string): Color3
	return Color3.fromHex(s)
end

Ui.C = {
	royal = hex("4169E1"),
	menuBg = hex("0000cd"),
	bone = hex("f6f3ea"),
	ink = hex("16181c"),
	rouge = hex("c0392b"),
	chalk = hex("c8d4f7"),
	white = Color3.new(1, 1, 1),
	black = Color3.new(0, 0, 0),
	navy = Color3.fromRGB(8, 14, 70),
	boardBg = Color3.fromRGB(10, 18, 80),
	primaryText = hex("1a1f6b"),
	goText = hex("231a06"),
	primaryHover = hex("e0ddd4"),
	bad = hex("f0a4a0"),
	selFill = Color3.fromRGB(130, 200, 255),
}
Ui.LINE_T = 0.70 -- --line: bone at 30%

---------------------------------------------------------------------------
-- fonts
---------------------------------------------------------------------------
local SERIF = "rbxasset://fonts/families/Merriweather.json"
local SANS = "rbxasset://fonts/families/BuilderSans.json"

function Ui.serif(weight: number?): Font
	-- Georgia only has regular and bold; 600 renders bold there too
	local w = weight or 700
	return Font.new(SERIF, if w >= 600 then Enum.FontWeight.Bold else Enum.FontWeight.Regular)
end

function Ui.sans(weight: number?): Font
	local w = weight or 400
	local fw = Enum.FontWeight.Regular
	if w >= 700 then
		fw = Enum.FontWeight.Bold
	elseif w >= 600 then
		fw = Enum.FontWeight.SemiBold
	elseif w >= 500 then
		fw = Enum.FontWeight.Medium
	end
	return Font.new(SANS, fw)
end

-- synchronous width estimate (TextService:GetTextSize only takes Enum.Font)
local measureCache = {}
function Ui.textWidth(text: string, size: number, family: string, weight: number?): number
	if text == "" or size <= 0 then
		return 0
	end
	local w = weight or 400
	local key = family .. "|" .. w .. "|" .. text
	local per = measureCache[key]
	if not per then
		local enum
		local factor = 1
		if family == "serif" then
			enum = Enum.Font.Merriweather
			if w >= 600 then
				factor = 1.06
			end
		else
			if w >= 600 then
				enum = Enum.Font.BuilderSansBold
				factor = 0.98
			elseif w >= 500 then
				enum = Enum.Font.BuilderSansMedium
			else
				enum = Enum.Font.BuilderSans
			end
		end
		local ok, v = pcall(function()
			return TextService:GetTextSize(text, 100, enum, Vector2.new(100000, 1000))
		end)
		per = if ok then v.X * factor / 100 else utf8.len(text) * 0.55
		measureCache[key] = per
	end
	return per * size
end

---------------------------------------------------------------------------
-- instance helper
---------------------------------------------------------------------------
function Ui.new(class: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(class)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				setProp(inst, k, v)
			end
		end
	end
	if children then
		for _, c in children do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function Ui.frame(props)
	local p = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}
	for k, v in props or {} do
		p[k] = v
	end
	return Ui.new("Frame", p)
end

function Ui.corner(parent: Instance, radius: number | UDim): UICorner
	return Ui.new("UICorner", {
		CornerRadius = if typeof(radius) == "UDim" then radius else UDim.new(0, radius),
		Parent = parent,
	})
end

function Ui.stroke(parent: Instance, color: Color3, transparency: number, thickness: number): UIStroke
	return Ui.new("UIStroke", {
		Color = color,
		Transparency = transparency,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Ui.label(props)
	local p = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		TextColor3 = Ui.C.bone,
		FontFace = Ui.sans(400),
		TextSize = 14,
		Text = "",
	}
	for k, v in props or {} do
		p[k] = v
	end
	return Ui.new("TextLabel", p)
end

function Ui.tween(inst: Instance, seconds: number, goal, style: Enum.EasingStyle?)
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		goal
	)
	tw:Play()
	return tw
end

-- letter-spacing via rich text: a sized space between characters
function Ui.spaced(text: string, gapSize: number): string
	local parts = {}
	for _, cp in utf8.codes(text) do
		table.insert(parts, Ui.escape(utf8.char(cp)))
	end
	return table.concat(parts, string.format('<font size="%d"> </font>', math.max(1, math.floor(gapSize))))
end

function Ui.escape(s: string): string
	s = string.gsub(s, "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	s = string.gsub(s, '"', "&quot;")
	s = string.gsub(s, "'", "&apos;")
	return s
end

---------------------------------------------------------------------------
-- big text: Roblox caps TextSize at 100, so larger type is rendered at
-- 100 and scaled up with a UIScale.
---------------------------------------------------------------------------
function Ui.bigText(props)
	local holder = Ui.frame({ Name = props.Name or "BigText", ZIndex = props.ZIndex, Parent = props.Parent })
	local label = Ui.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		FontFace = props.FontFace,
		TextColor3 = props.TextColor3 or Ui.C.bone,
		Text = props.Text or "",
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		RichText = props.RichText or false,
		ZIndex = props.ZIndex,
		Parent = holder,
	})
	local scale = Ui.new("UIScale", { Parent = label })
	local obj = { holder = holder, label = label, scale = scale, size = 14 }
	function obj.setSize(fontSize: number)
		obj.size = fontSize
		local base = math.clamp(math.floor(fontSize), 1, 100)
		label.TextSize = base
		local k = fontSize / base
		scale.Scale = k
		label.Size = UDim2.fromScale(1 / k, 1 / k)
	end
	obj.setSize(props.TextSize or 14)
	return obj
end

---------------------------------------------------------------------------
-- drawn glyphs
---------------------------------------------------------------------------
local function shapePart(parent, props)
	local f = Ui.frame({
		BackgroundTransparency = 0,
		BackgroundColor3 = props.color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(props.x, props.y),
		Size = UDim2.fromScale(props.w, props.h),
		Rotation = props.rot or 0,
		ZIndex = props.z,
		Parent = parent,
	})
	if props.round then
		Ui.corner(f, UDim.new(0.5, 0))
	end
	return f
end

-- a right-isosceles triangle: the half of a 45°-turned square that points
-- toward `apexDeg` (0 = right, 90 = down, -90 = up)
local function trianglePart(parent, x, y, side, apexDeg, color, z)
	local f = shapePart(parent, { x = x, y = y, w = side, h = side, rot = 45, color = color, z = z })
	Ui.new("UIGradient", {
		Rotation = apexDeg - 45,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.499, 1),
			NumberSequenceKeypoint.new(0.501, 0),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = f,
	})
	return f
end
Ui.trianglePart = trianglePart

--[[
	Ui.suit(kind, color, z) -> Frame (square; size it yourself)
	kind: 1 spade, 2 heart, 3 diamond, 4 club
]]
function Ui.suit(kind: number, color: Color3, z: number?)
	local box = Ui.frame({ Name = "Suit", ZIndex = z })
	local function part(p)
		p.color = color
		p.z = z
		return shapePart(box, p)
	end
	if kind == 2 then
		local s = 0.586
		part({ x = 0.5, y = 0.543, w = s, h = s, rot = 45 })
		part({ x = 0.293, y = 0.336, w = s, h = s, round = true })
		part({ x = 0.707, y = 0.336, w = s, h = s, round = true })
	elseif kind == 3 then
		part({ x = 0.5, y = 0.5, w = 0.6, h = 0.6, rot = 45 })
	elseif kind == 1 then
		local s = 0.5
		part({ x = 0.5, y = 0.40, w = s, h = s, rot = 45 })
		part({ x = 0.323, y = 0.577, w = s, h = s, round = true })
		part({ x = 0.677, y = 0.577, w = s, h = s, round = true })
		part({ x = 0.5, y = 0.78, w = 0.075, h = 0.32 })
		trianglePart(box, 0.5, 0.985, 0.33, -90, color, z)
	else
		local d = 0.41
		part({ x = 0.5, y = 0.255, w = d, h = d, round = true })
		part({ x = 0.285, y = 0.555, w = d, h = d, round = true })
		part({ x = 0.715, y = 0.555, w = d, h = d, round = true })
		part({ x = 0.5, y = 0.47, w = 0.26, h = 0.26, round = true })
		part({ x = 0.5, y = 0.76, w = 0.075, h = 0.34 })
		trianglePart(box, 0.5, 0.985, 0.33, -90, color, z)
	end
	return box
end

-- ✕ drawn from two bars; returns frame and a recolour function
function Ui.cross(color: Color3, thickness: number, z: number?)
	local box = Ui.frame({ Name = "Cross", ZIndex = z })
	local bars = {}
	for _, r in { 45, -45 } do
		local b = Ui.frame({
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1.2, 0, 0, thickness),
			Rotation = r,
			ZIndex = z,
			Parent = box,
		})
		table.insert(bars, b)
	end
	local function set(c: Color3, t: number?)
		for _, b in bars do
			b.BackgroundColor3 = c
			b.BackgroundTransparency = t or 0
		end
	end
	return box, set
end

-- ✓ drawn from two bars
function Ui.check(color: Color3, thickness: number, z: number?, transparency: number?)
	local box = Ui.frame({ Name = "Check", ZIndex = z })
	local function bar(x, y, len, rot)
		Ui.frame({
			BackgroundTransparency = transparency or 0,
			BackgroundColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.new(len, 0, 0, thickness),
			Rotation = rot,
			ZIndex = z,
			Parent = box,
		})
	end
	bar(0.27, 0.62, 0.42, 45)
	bar(0.6, 0.47, 0.78, -55)
	return box
end

-- ▸ small triangle; rotate the returned frame to turn it
function Ui.chevron(color: Color3, z: number?)
	local box = Ui.frame({ Name = "Chevron", ZIndex = z })
	-- apex right; shift left so the visible half is centred
	trianglePart(box, 0.30, 0.5, 0.62, 0, color, z)
	return box
end

---------------------------------------------------------------------------
-- buttons with the web version's hover / press / disabled states
---------------------------------------------------------------------------
--[[
	styles: each has normal / hover / disabled states of
	{ bg, bgT, stroke, strokeT, text, textT }
]]
local W = Ui.C.white
local STYLES = {
	btn = {
		normal = { bg = W, bgT = 0.82, stroke = W, strokeT = 0.45, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.70, stroke = W, strokeT = 0.20, text = Ui.C.bone, textT = 0 },
		pressScale = 0.97,
		strokeW = 1.5,
	},
	primary = {
		normal = { bg = Ui.C.bone, bgT = 0, stroke = Ui.C.bone, strokeT = 0, text = Ui.C.primaryText, textT = 0 },
		hover = { bg = Ui.C.primaryHover, bgT = 0, stroke = Ui.C.primaryHover, strokeT = 0, text = Ui.C.primaryText, textT = 0 },
		disabled = { bg = W, bgT = 0.82, stroke = W, strokeT = 0.70, text = W, textT = 0.55 },
		pressScale = 0.97,
		strokeW = 1.5,
	},
	vote = {
		normal = { bg = W, bgT = 0.76, stroke = W, strokeT = 0.25, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.70, stroke = W, strokeT = 0.20, text = Ui.C.bone, textT = 0 },
		pressScale = 0.97,
		strokeW = 1.5,
	},
	voteCast = {
		normal = { bg = W, bgT = 0.90, stroke = W, strokeT = 0.65, text = Ui.C.chalk, textT = 0 },
		hover = { bg = W, bgT = 0.70, stroke = W, strokeT = 0.20, text = Ui.C.chalk, textT = 0 },
		pressScale = 0.97,
		strokeW = 1.5,
	},
	opkey = {
		normal = { bg = W, bgT = 0.82, stroke = W, strokeT = 0.45, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.70, stroke = W, strokeT = 0.20, text = Ui.C.bone, textT = 0 },
		pressScale = 0.94,
		strokeW = 1.5,
	},
	go = {
		normal = { bg = Ui.C.bone, bgT = 0, stroke = Ui.C.bone, strokeT = 0, text = Ui.C.goText, textT = 0 },
		hover = { bg = Ui.C.bone, bgT = 0.08, stroke = Ui.C.bone, strokeT = 0.08, text = Ui.C.goText, textT = 0.08 },
		pressScale = 0.985,
		strokeW = 1,
	},
	ghost = {
		normal = { bg = Ui.C.bone, bgT = 1, stroke = Ui.C.bone, strokeT = Ui.LINE_T, text = Ui.C.bone, textT = 0 },
		hover = { bg = Ui.C.bone, bgT = 0.92, stroke = Ui.C.bone, strokeT = Ui.LINE_T, text = Ui.C.bone, textT = 0 },
		pressScale = 0.985,
		strokeW = 1,
	},
	plain = {
		normal = { bg = W, bgT = 1, stroke = W, strokeT = 1, text = Ui.C.chalk, textT = 0 },
		hover = { bg = W, bgT = 1, stroke = W, strokeT = 1, text = Ui.C.chalk, textT = 0 },
		strokeW = 0,
	},
	logToggle = {
		normal = { bg = W, bgT = 0.90, stroke = Ui.C.bone, strokeT = Ui.LINE_T, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.82, stroke = Ui.C.bone, strokeT = Ui.LINE_T, text = Ui.C.bone, textT = 0 },
		strokeW = 1,
	},
	logHead = {
		normal = { bg = W, bgT = 0.91, stroke = W, strokeT = 0.84, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.83, stroke = W, strokeT = 0.84, text = Ui.C.bone, textT = 0 },
		strokeW = 1,
	},
	close = {
		normal = { bg = W, bgT = 0.86, stroke = W, strokeT = 0.65, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 0.72, stroke = W, strokeT = 0.65, text = Ui.C.bone, textT = 0 },
		strokeW = 1,
	},
	quit = {
		normal = { bg = W, bgT = 1, stroke = W, strokeT = 0.60, text = W, textT = 0.30 },
		hover = { bg = W, bgT = 1, stroke = W, strokeT = 0.15, text = Ui.C.bone, textT = 0 },
		strokeW = 1.5,
	},
	link = {
		normal = { bg = W, bgT = 1, stroke = W, strokeT = 1, text = Ui.C.bone, textT = 0 },
		hover = { bg = W, bgT = 1, stroke = W, strokeT = 1, text = Ui.C.bone, textT = 0.2 },
		strokeW = 0,
	},
}
Ui.STYLES = STYLES

local function dimmed(s, amount)
	-- CSS opacity multiplies every layer's alpha
	local function t(x)
		return 1 - (1 - x) * amount
	end
	return { bg = s.bg, bgT = t(s.bgT), stroke = s.stroke, strokeT = t(s.strokeT), text = s.text, textT = t(s.textT) }
end

--[[
	Ui.button{ style, Text, FontFace, TextSize, radius, Parent, ZIndex, onClick }
	returns an object: { inst, stroke, scale, setDisabled, setStyle, setText, setHidden }
]]
function Ui.button(opts)
	local inst = Ui.new("TextButton", {
		Name = opts.Name or "Button",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = opts.Text or "",
		RichText = opts.RichText or false,
		FontFace = opts.FontFace or Ui.sans(600),
		TextSize = opts.TextSize or 14,
		ZIndex = opts.ZIndex,
		ClipsDescendants = false,
		Parent = opts.Parent,
	})
	local corner = Ui.corner(inst, opts.radius or 0)
	local stroke = Ui.stroke(inst, Ui.C.white, 1, 1)
	local scale = Ui.new("UIScale", { Parent = inst })
	local obj = {
		inst = inst,
		corner = corner,
		stroke = stroke,
		scale = scale,
		style = opts.style or "btn",
		disabled = false,
		hovered = false,
		onStyle = nil, -- optional callback(stateTable) for drawn icons
	}

	local function apply(animated: boolean)
		local st = STYLES[obj.style]
		local s
		if obj.disabled then
			s = st.disabled or dimmed(st.normal, 0.35)
		elseif obj.hovered then
			s = st.hover
		else
			s = st.normal
		end
		stroke.Thickness = st.strokeW or 1
		local goalBtn = {
			BackgroundColor3 = s.bg,
			BackgroundTransparency = s.bgT,
			TextColor3 = s.text,
			TextTransparency = s.textT,
		}
		local goalStroke = { Color = s.stroke, Transparency = if (st.strokeW or 1) <= 0 then 1 else s.strokeT }
		if animated then
			Ui.tween(inst, 0.17, goalBtn)
			Ui.tween(stroke, 0.17, goalStroke)
		else
			for k, v in goalBtn do
				setProp(inst, k, v)
			end
			for k, v in goalStroke do
				setProp(stroke, k, v)
			end
		end
		if obj.onStyle then
			obj.onStyle(s, animated)
		end
	end
	obj.apply = apply

	inst.MouseEnter:Connect(function()
		obj.hovered = true
		apply(true)
	end)
	inst.MouseLeave:Connect(function()
		obj.hovered = false
		apply(true)
		scale.Scale = 1
	end)
	local pressAnim = nil
	local function press(down: boolean)
		local st = STYLES[obj.style]
		if not st.pressScale or obj.disabled then
			scale.Scale = 1
			return
		end
		if pressAnim then
			pressAnim:Cancel()
		end
		local from = scale.Scale
		local to = if down then st.pressScale else 1
		pressAnim = Anim.run(0.09, Anim.EASE, function(e)
			scale.Scale = Anim.lerp(from, to, e)
		end)
	end
	inst.MouseButton1Down:Connect(function()
		press(true)
	end)
	inst.MouseButton1Up:Connect(function()
		press(false)
	end)
	inst.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.Touch then
			press(false)
			-- touch has no hover
			obj.hovered = false
			apply(true)
		end
	end)
	inst.Activated:Connect(function()
		if obj.disabled then
			return
		end
		if opts.onClick then
			opts.onClick()
		end
	end)

	function obj.setDisabled(d: boolean)
		d = d and true or false
		if obj.disabled == d then
			return
		end
		obj.disabled = d
		inst.AutoButtonColor = false
		apply(false)
	end
	function obj.setStyle(name: string)
		if obj.style == name then
			return
		end
		obj.style = name
		apply(false)
	end
	function obj.setText(t: string)
		inst.Text = t
	end
	apply(false)
	return obj
end

return Ui

--[[
	Play — the card table: HUD, hand, equation bar, controls, standings,
	vote-to-skip, the solutions panel and the ready/set/go curtain.

	Layout is computed here rather than by Roblox layout objects so the web
	version's fluid sizing (--ch, --fit, the 90px bottom gap, the narrow /
	wide breakpoints) and its FLIP card motion carry over one-to-one.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("TwentyFour")
local Solver = require(Shared:WaitForChild("Solver"))
local Ui = require(script.Parent:WaitForChild("Ui"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local C = Ui.C
local V2 = Vector2.new
local px = UDim2.fromOffset

local Play = {}

-- board state (section 3 of the web version)
local S = {
	puzzle = {},
	eqItems = {}, -- { {type="card", id} | {type="op", op} }
	groups = {}, -- { {id, from, to} } eqItems indices
	groupSeq = 1,
	locked = true,
	mode = nil, -- "solo" | "mp"
	solved = 0,
	best = 0,
	puzzleSolved = false,
	canShowOthers = false,
	solutionCache = nil,
	dragging = false,
	suppressUntil = 0,
}
Play.S = S

-- hooks the flow controller fills in
Play.hooks = {
	onQuit = function() end,
	onHome = function() end,
	onSoloSolved = function() end,
	onMpClaim = function(_toks) end,
	onVote = function() end,
	isOverlayVisible = function()
		return false
	end,
}

local E = {} -- elements
local L = { fit = 1, W = 0, H = 0, playW = 0 } -- last layout
local V = { -- view state
	hudHidden = true,
	restHidden = true,
	phase3T = 1,
	shakeX = 0,
	solShown = false,
	solCollapsed = false,
	sheetOffset = 0,
	boardShown = false,
	boardCollapsed = false,
	boardCustom = nil, -- Vector2 when dragged
	boardRows = 0,
	boardClock = "30s",
	readout = { text = "", kind = nil, link = false, show = false },
	readoutT = 1,
	isMp = false,
	bestShown = false,
	timeShown = false,
	timeLabel = "time",
	timeValue = "30",
	nextShown = false,
	vote = nil, -- { head, names, iVoted } when shown
	curtainShown = false,
}

local cardNodes = {}
local slotEls = {}
local opCache = {} -- eqItems index -> node
local parenCache = {} -- group id -> { open, close }
local prevSeq = {} -- node -> true (what was on the bar last render)

local function clamp(lo: number, v: number, hi: number): number
	return math.max(lo, math.min(v, hi))
end

local function clickOk(): boolean
	return not S.dragging and os.clock() >= S.suppressUntil
end
Play.clickOk = clickOk

---------------------------------------------------------------------------
-- nodes: every hand / equation element (holder = layout, body = motion)
---------------------------------------------------------------------------
local Node = {}
Node.__index = Node

local function newNode(kind: string, body: GuiObject)
	local holder = Ui.frame({
		Name = kind,
		AnchorPoint = V2(0.5, 0.5),
		Size = px(0, 0),
		ZIndex = 5,
		Visible = false,
		Parent = E.layer,
	})
	body.AnchorPoint = V2(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Parent = holder
	local sc = Ui.new("UIScale", { Parent = body })
	return setmetatable({
		kind = kind,
		holder = holder,
		body = body,
		sc = sc,
		cx = 0,
		cy = 0,
		w = 0,
		h = 0,
		k = 1,
		ls = 1,
		offX = 0,
		offY = 0,
		pop = 1,
		rot = 0,
		alpha = 0,
		baseT = 0,
		inEq = false,
		anims = {},
	}, Node)
end

function Node:apply()
	self.holder.Position = px(self.cx, self.cy)
	local shake = if self.inEq then V.shakeX else 0
	self.body.Position = UDim2.new(0.5, self.offX + shake, 0.5, self.offY)
	self.body.Rotation = self.rot
	self.sc.Scale = math.max(0.001, self.k * self.ls * self.pop)
	self:applyAlpha()
end

function Node:applyAlpha()
	if self.kind == "card" then
		self.body.GroupTransparency = self.alpha
	else
		local vis = (1 - self.alpha) * (1 - self.baseT) * (1 - V.phase3T)
		self.body.TextTransparency = 1 - vis
	end
end

function Node:setBase(w: number, h: number, fs: number?)
	self.w, self.h = w, h
	if fs then
		local base = math.clamp(math.floor(fs + 0.5), 1, 100)
		self.body.TextSize = base
		self.k = fs / base
		self.body.Size = px(w / self.k, h / self.k)
	else
		self.k = 1
		self.body.Size = px(w, h)
	end
end

function Node:stop(channel: string)
	local a = self.anims[channel]
	if a then
		a:Cancel()
		self.anims[channel] = nil
	end
end

function Node:destroy()
	for ch in self.anims do
		self:stop(ch)
	end
	self.holder:Destroy()
end

function Node:visual(): (number, number, number)
	return self.cx + self.offX, self.cy + self.offY, self.ls * self.pop
end

-- visual rectangle in root coordinates
function Node:rect()
	local x, y, s = self:visual()
	local hw, hh = self.w * s / 2, self.h * s / 2
	return { left = x - hw, right = x + hw, top = y - hh, bottom = y + hh }
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------
local function makeCard(idx: number, c)
	local red = Solver.SUIT_RED[c.s] or false
	local color = if red then C.rouge else C.ink
	local body = Ui.new("CanvasGroup", {
		Name = "Card",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 5,
	})
	local border = Ui.frame({
		Name = "Border",
		BackgroundTransparency = 0.72,
		BackgroundColor3 = C.black,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = body,
	})
	Ui.corner(border, 10)
	local face = Ui.frame({
		Name = "Face",
		BackgroundTransparency = 0,
		BackgroundColor3 = C.bone,
		Position = px(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		ZIndex = 2,
		Parent = body,
	})
	Ui.corner(face, 9)
	local label = Solver.rankLabel(c.v)
	local corner = Ui.label({
		Name = "Corner",
		Text = label,
		FontFace = Ui.serif(700),
		TextColor3 = color,
		TextTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 3,
		Parent = body,
	})
	local rank = Ui.label({
		Name = "Rank",
		Text = label,
		FontFace = Ui.serif(700),
		TextColor3 = color,
		ZIndex = 3,
		Parent = body,
	})
	local suit = Ui.suit(c.s, color, 3)
	suit.AnchorPoint = V2(0.5, 0.5)
	suit.Parent = body
	local hit = Ui.new("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = body,
	})
	local node = newNode("card", body)
	node.id = idx
	node.parts = { border = border, corner = corner, rank = rank, suit = suit }
	node.alpha = 0
	hit.MouseEnter:Connect(function()
		Ui.tween(border, 0.17, { BackgroundTransparency = 0.55 })
	end)
	hit.MouseLeave:Connect(function()
		Ui.tween(border, 0.17, { BackgroundTransparency = 0.72 })
	end)
	hit.Activated:Connect(function()
		Play.onCardClick(idx)
	end)
	return node
end

local function sizeCard(node, cw: number, ch: number)
	if node.lastCh == ch then
		return
	end
	node.lastCh = ch
	node:setBase(cw, ch)
	local p = node.parts
	p.corner.Position = px(7, 5)
	p.corner.TextSize = math.max(1, ch * 0.135)
	p.corner.Size = px(cw, ch * 0.2)
	local rs = ch * 0.34
	p.rank.TextSize = math.max(1, rs)
	p.rank.Size = px(cw, rs * 1.3)
	p.rank.Position = px(0, ch * 0.38 - rs * 0.65)
	local ss = ch * 0.165
	p.suit.Size = px(ss, ss)
	p.suit.Position = px(cw / 2, ch * 0.685)
end

local function setParenHot(gid: number, on: boolean)
	local p = parenCache[gid]
	if not p then
		return
	end
	for _, n in { p.open, p.close } do
		Ui.tween(n.body, 0.17, { TextColor3 = if on then C.ink else C.bone })
	end
end

local function makeParen(g, ch: string)
	local body = Ui.new("TextButton", {
		Name = "Paren",
		Text = ch,
		FontFace = Ui.serif(400),
		TextColor3 = C.bone,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 5,
	})
	local node = newNode("paren", body)
	node.gid = g.id
	node.ch = ch
	body.MouseEnter:Connect(function()
		setParenHot(g.id, true)
	end)
	body.MouseLeave:Connect(function()
		setParenHot(g.id, false)
	end)
	body.Activated:Connect(function()
		if clickOk() then
			Play.removeGroup(g.id)
		end
	end)
	return node
end

local function parenNodes(g)
	local p = parenCache[g.id]
	if not p then
		p = { open = makeParen(g, "("), close = makeParen(g, ")") }
		parenCache[g.id] = p
	end
	return p
end

local function opNode(i: number, op: string)
	local n = opCache[i]
	if n and n.op == op then
		return n
	end
	if n then
		n:destroy()
	end
	local body = Ui.label({
		Name = "Op",
		Text = Solver.GLYPH[op],
		FontFace = Ui.serif(600),
		TextColor3 = C.bone,
		ZIndex = 5,
	})
	n = newNode("op", body)
	n.op = op
	opCache[i] = n
	return n
end

---------------------------------------------------------------------------
-- build the static screen
---------------------------------------------------------------------------
local function statBlock(parent, name: string, lbl: string, val: string)
	local f = Ui.frame({ Name = name, ZIndex = 3, Parent = parent })
	local l = Ui.label({
		Name = "Lbl",
		Text = lbl,
		TextColor3 = C.chalk,
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Ui.sans(400),
		ZIndex = 3,
		Parent = f,
	})
	local v = Ui.label({
		Name = "Val",
		Text = val,
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Ui.serif(700),
		ZIndex = 3,
		Parent = f,
	})
	return { frame = f, lbl = l, val = v }
end

function Play.init(gui: ScreenGui, selGui: ScreenGui)
	local root = Ui.frame({ Name = "PlayRoot", Size = UDim2.fromScale(1, 1), Parent = gui })
	E.root = root

	-- table layer: slots, cards, operators, parentheses, readout
	E.layer = Ui.frame({ Name = "Table", Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = root })

	for i = 1, 4 do
		local slot = Ui.frame({
			Name = "Slot" .. i,
			BackgroundColor3 = C.black,
			BackgroundTransparency = 1,
			AnchorPoint = V2(0.5, 0.5),
			ZIndex = 1,
			Parent = E.layer,
		})
		Ui.corner(slot, 10)
		slotEls[i] = slot
	end

	local hintBody = Ui.label({
		Name = "Hint",
		Text = "tap a card to start building",
		TextColor3 = C.chalk,
		FontFace = Ui.sans(400),
		ZIndex = 5,
	})
	E.hint = newNode("hint", hintBody)
	E.hint.baseT = 0.2

	-- readout
	E.readout = Ui.frame({ Name = "Readout", ZIndex = 5, Parent = E.layer })
	E.readoutText = Ui.label({
		Name = "Text",
		TextColor3 = C.chalk,
		FontFace = Ui.serif(600),
		TextWrapped = true,
		TextTransparency = 1,
		ZIndex = 5,
		Parent = E.readout,
	})
	E.readoutLink = Ui.new("TextButton", {
		Name = "Link",
		Text = "<u>show other solutions</u>",
		RichText = true,
		FontFace = Ui.sans(600),
		TextColor3 = C.bone,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		TextTransparency = 1,
		Visible = false,
		ZIndex = 6,
		Parent = E.readout,
	})
	E.readoutLink.MouseEnter:Connect(function()
		E.readoutLinkHover = true
		Play.applyReadoutAlpha()
	end)
	E.readoutLink.MouseLeave:Connect(function()
		E.readoutLinkHover = false
		Play.applyReadoutAlpha()
	end)
	E.readoutLink.Activated:Connect(function()
		if clickOk() then
			Play.openSolutionsPanel()
		end
	end)

	-- header (+ rule) --------------------------------------------------------
	local header = Ui.new("CanvasGroup", {
		Name = "Header",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
		Visible = false,
		Parent = root,
	})
	E.header = header
	E.mark = Ui.new("TextButton", {
		Name = "Mark",
		Text = "24",
		FontFace = Ui.serif(700),
		TextColor3 = C.bone,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
		Parent = header,
	})
	E.mark.MouseEnter:Connect(function()
		Ui.tween(E.mark, 0.12, { TextTransparency = 0.22 })
	end)
	E.mark.MouseLeave:Connect(function()
		Ui.tween(E.mark, 0.12, { TextTransparency = 0 })
	end)
	E.mark.MouseButton1Down:Connect(function()
		E.mark.TextTransparency = 0.4
	end)
	E.mark.Activated:Connect(function()
		E.mark.TextTransparency = 0
		if clickOk() then
			Play.hooks.onHome()
		end
	end)
	E.sub = Ui.label({
		Name = "Sub",
		Text = "use all four cards, once each",
		TextColor3 = C.chalk,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 3,
		Parent = header,
	})
	E.solvedStat = statBlock(header, "Solved", "solved", "0")
	E.timeStat = statBlock(header, "Time", "time", "30")
	E.bestStat = statBlock(header, "Best", "best", "0")

	local quit = Ui.button({
		Name = "Quit",
		style = "quit",
		radius = UDim.new(0.5, 0),
		ZIndex = 3,
		Parent = header,
		onClick = function()
			if clickOk() then
				Play.hooks.onQuit()
			end
		end,
	})
	local cross, setCross = Ui.cross(C.white, 1.5, 4)
	cross.AnchorPoint = V2(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = px(9, 9)
	cross.Parent = quit.inst
	quit.onStyle = function(s)
		setCross(s.text, s.textT)
	end
	quit.apply(false)
	E.quit = quit

	E.rule = Ui.frame({
		Name = "Rule",
		BackgroundTransparency = Ui.LINE_T,
		BackgroundColor3 = C.bone,
		ZIndex = 3,
		Parent = header,
	})

	-- controls ---------------------------------------------------------------
	local controls = Ui.new("CanvasGroup", {
		Name = "Controls",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
		Visible = false,
		Parent = root,
	})
	E.controls = controls
	E.opKeys = {}
	for _, op in Solver.OPS do
		local b = Ui.button({
			Name = "Op" .. op,
			style = "opkey",
			Text = Solver.GLYPH[op],
			FontFace = Ui.serif(600),
			ZIndex = 3,
			Parent = controls,
			onClick = function()
				Play.onOpClick(op)
			end,
		})
		table.insert(E.opKeys, b)
	end
	local function act(name, label, style, fn)
		local b = Ui.button({
			Name = name,
			style = style,
			Text = label,
			FontFace = Ui.sans(600),
			ZIndex = 3,
			Parent = controls,
			onClick = fn,
		})
		b.label = label
		b.primary = style == "primary"
		return b
	end
	E.clearBtn = act("Clear", "Clear", "btn", function()
		if clickOk() then
			Play.clearEquation()
		end
	end)
	E.solutionBtn = act("Solution", "Solution", "btn", function()
		Play.onSolutionClick()
	end)
	E.submitBtn = act("Submit", "Submit", "primary", function()
		if clickOk() then
			Play.onSubmit()
		end
	end)
	E.nextBtn = act("Next", "Next", "primary", function()
		if clickOk() then
			Play.advancePuzzle()
		end
	end)
	E.skipBtn = act("Skip", "Skip", "btn", function()
		if S.locked or not clickOk() or S.mode == "mp" then
			return
		end
		Play.replaceHand(nil, { keepSay = true })
	end)
	E.acts = { E.clearBtn, E.solutionBtn, E.submitBtn, E.nextBtn, E.skipBtn }

	-- standings --------------------------------------------------------------
	local board = Ui.new("CanvasGroup", {
		Name = "Standings",
		BackgroundColor3 = C.boardBg,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		ZIndex = 4,
		Visible = false,
		Parent = root,
	})
	Ui.corner(board, 12)
	local bs = Ui.stroke(board, C.bone, Ui.LINE_T, 1)
	pcall(function()
		local anyStroke: any = bs
		anyStroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	end)
	E.board = board
	E.boardHead = Ui.new("TextButton", {
		Name = "Head",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		ZIndex = 4,
		Parent = board,
	})
	E.boardTitle = Ui.label({
		Text = "standings",
		TextSize = 10.5,
		TextColor3 = C.chalk,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = E.boardHead,
	})
	E.boardClock = Ui.label({
		Text = "30s",
		TextSize = 10.5,
		TextColor3 = C.chalk,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 4,
		Parent = E.boardHead,
	})
	E.boardChev = Ui.chevron(C.chalk, 4)
	E.boardChev.AnchorPoint = V2(0.5, 0.5)
	E.boardChev.Size = px(8, 8)
	E.boardChev.Rotation = 90
	E.boardChev.Parent = E.boardHead
	E.boardDivider = Ui.frame({
		BackgroundTransparency = Ui.LINE_T,
		BackgroundColor3 = C.bone,
		ZIndex = 4,
		Parent = board,
	})
	E.boardRows = Ui.frame({ Name = "Rows", ZIndex = 4, Parent = board })
	Play.initBoardDrag()

	-- vote to skip ------------------------------------------------------------
	local votebar = Ui.frame({ Name = "VoteBar", ZIndex = 6, Visible = false, Parent = root })
	E.votebar = votebar
	E.voteList = Ui.frame({
		Name = "List",
		BackgroundTransparency = 0.3,
		BackgroundColor3 = C.boardBg,
		ZIndex = 6,
		Parent = votebar,
	})
	Ui.corner(E.voteList, 10)
	E.voteBtn = Ui.button({
		Name = "Vote",
		style = "vote",
		Text = "Vote to skip this hand",
		FontFace = Ui.sans(600),
		ZIndex = 6,
		Parent = votebar,
		onClick = function()
			Play.hooks.onVote()
		end,
	})

	-- curtain ----------------------------------------------------------------
	E.curtain = Ui.frame({
		Name = "Curtain",
		BackgroundTransparency = 0,
		BackgroundColor3 = C.royal,
		ZIndex = 7,
		Visible = false,
		Active = true,
		Parent = root,
	})
	E.curtainWord = Ui.bigText({ Name = "Word", FontFace = Ui.serif(700), ZIndex = 8, Parent = E.curtain })
	E.curtainWord.holder.AnchorPoint = V2(0.5, 0.5)
	E.curtainWord.holder.Position = UDim2.fromScale(0.5, 0.5)

	-- solutions panel ------------------------------------------------------------
	local sol = Ui.frame({
		Name = "Solutions",
		BackgroundTransparency = 0.45,
		BackgroundColor3 = C.navy,
		ZIndex = 20,
		Visible = false,
		Active = true,
		ClipsDescendants = true,
		Parent = root,
	})
	E.sol = sol
	E.solCorner = Ui.corner(sol, 0)
	E.solEdge = Ui.frame({ BackgroundTransparency = Ui.LINE_T, BackgroundColor3 = C.bone, ZIndex = 21, Parent = sol })
	E.solHead = Ui.new("TextButton", {
		Name = "Head",
		Text = "",
		BackgroundColor3 = C.white,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		ZIndex = 21,
		Parent = sol,
	})
	E.solHead.MouseEnter:Connect(function()
		Ui.tween(E.solHead, 0.12, { BackgroundTransparency = 0.93 })
	end)
	E.solHead.MouseLeave:Connect(function()
		Ui.tween(E.solHead, 0.12, { BackgroundTransparency = 1 })
	end)
	E.solHead.Activated:Connect(function()
		Play.toggleSolutionsPanel()
	end)
	E.solTitle = Ui.label({
		Text = "Other solutions",
		FontFace = Ui.sans(600),
		TextSize = 12.5,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 21,
		Parent = E.solHead,
	})
	E.solCount = Ui.label({
		Text = "–",
		TextSize = 10.5,
		TextColor3 = C.chalk,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 21,
		Parent = E.solHead,
	})
	E.solChev = Ui.chevron(C.chalk, 21)
	E.solChev.AnchorPoint = V2(0.5, 0.5)
	E.solChev.Size = px(8, 8)
	E.solChev.Parent = E.solHead
	E.solHeadLine = Ui.frame({ BackgroundTransparency = Ui.LINE_T, BackgroundColor3 = C.bone, ZIndex = 21, Parent = sol })
	E.solBody = Ui.new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.chalk,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = px(0, 0),
		ZIndex = 21,
		Parent = sol,
	})

	-- drag-selection box (own layer, above everything in play)
	E.selbox = Ui.frame({
		Name = "SelBox",
		BackgroundTransparency = 0.78,
		BackgroundColor3 = C.selFill,
		Visible = false,
		ZIndex = 40,
		Parent = selGui,
	})
	Ui.corner(E.selbox, 5)
	Ui.stroke(E.selbox, C.selFill, 0.15, 1.5)

	-- score pop
	E.pops = Ui.frame({ Name = "Pops", ZIndex = 5, Parent = header })

	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Play.layout()
	end)

	Play.initInput()
	Play.dealNew(nil, { deal = false, locked = true })
	Play.syncControls(true)
	Play.layout()
end

---------------------------------------------------------------------------
-- layout (the CSS sizing system, computed)
---------------------------------------------------------------------------
local function headerMetrics(W: number, H: number)
	local m = { padT = 14, padB = 12, padX = 22, markFs = 30, statVal = 22, statLbl = 10, subShown = true, gap = 20 }
	if W <= 760 then
		m.padT, m.padB, m.padX = 10, 8, 12
		m.markFs, m.subShown, m.gap, m.statVal = 23, false, 12, 18
	end
	if W <= 420 then
		m.padT, m.padB, m.padX = 8, 6, 10
		m.markFs, m.gap, m.statLbl, m.statVal = 20, 9, 9, 16
	end
	if H <= 620 then
		m.padT, m.padB, m.padX = 8, 6, 14
		m.statVal = 17
	end
	m.lblH = m.statLbl * 1.28
	m.valH = m.statVal * 1.05
	m.statH = m.lblH + m.valH
	m.contentH = math.max(m.markFs * 0.85, m.statH, 30)
	m.h = m.padT + m.contentH + m.padB
	return m
end

local function boardWidth()
	local nameW, scoreW = 0, 0
	for _, r in E.boardRowData or {} do
		nameW = math.max(nameW, r.nameW)
		scoreW = math.max(scoreW, r.scoreW)
	end
	local rowW = 12 + 14 + 8 + nameW + 8 + scoreW + 12 + 2
	local headW = 24 + Ui.textWidth("standings", 10.5, "sans") + 12 + Ui.textWidth(V.boardClock, 10.5, "sans") + 2
	return clamp(172, math.max(rowW, headW), 220)
end

local function boardHeight(): number
	local head = 8 + 7 + 10.5 * 1.3 + 1
	if V.boardCollapsed and L.skinny then
		return head + 2
	end
	return head + 5 + 7 + V.boardRows * 25 + 2
end

local function readoutMetrics(f: number, maxW: number)
	local r = V.readout
	local kind = r.kind
	local family, weight, fs = "serif", 600, clamp(13, 2 * L.vh, 19) * f
	if kind == "note" then
		family, weight, fs = "sans", 500, clamp(11, 1.6 * L.vh, 13) * f
	end
	local lfs = clamp(11, 1.6 * L.vh, 13.5) * f
	local tw = Ui.textWidth(r.text, fs, family, weight)
	local showLink = r.link and S.canShowOthers
	local lw = if showLink then Ui.textWidth("show other solutions", lfs, "sans", 600) + 2 else 0
	local gap = if showLink and r.text ~= "" then fs * 0.5 else 0
	local lineH = fs * 1.25
	local m = { fs = fs, lfs = lfs, family = family, weight = weight, tw = tw, lw = lw, gap = gap, showLink = showLink }
	if r.text == "" and not showLink then
		m.h = 22 * f
		m.lines = 0
		return m
	end
	if tw + gap + lw <= maxW then
		m.oneLine = true
		m.textLines = 1
		m.h = math.max(22 * f, math.max(lineH, if showLink then lfs * 1.3 else 0))
	else
		m.oneLine = false
		m.textLines = math.max(1, math.ceil(tw / maxW))
		m.h = m.textLines * lineH + (if showLink then lfs * 1.3 else 0)
		m.h = math.max(22 * f, m.h)
	end
	return m
end

local function visibleActs()
	local list = {}
	for _, b in E.acts do
		if b.inst.Visible then
			table.insert(list, b)
		end
	end
	return list
end

local function sizesFor(f: number)
	local vw, vh = L.vw, L.vh
	local z = {}
	z.ch = clamp(64, math.min(23 * vh, 22 * vw), 186) * f
	z.cw = z.ch * 0.71
	z.handGap = clamp(7, 2.2 * vw, 30) * f
	z.eqGap = clamp(4, 1.1 * vw, 14) * f
	z.opsz = clamp(42, math.min(9.5 * vh, 13 * vw), 116) * f
	z.btnPy = clamp(10, 2.3 * vh, 24) * f
	z.btnPx = clamp(13, 3 * vw, 42) * f
	z.btnFs = clamp(12, math.min(2.2 * vh, 3.4 * vw), 24) * f
	z.ctlGap = clamp(9, 2.2 * vh, 22) * f
	z.tableGap = clamp(8, 2.2 * vh, 30)
	z.tablePad = 10 * f
	z.btnH = z.btnFs * 1.28 + 2 * z.btnPy + 3
	-- action rows (flex-wrap, centred)
	local maxW = L.playW - 24
	local rows = { { items = {}, w = 0 } }
	for _, b in visibleActs() do
		local w = Ui.textWidth(b.inst.Text, z.btnFs, "sans", 600) + 2 * z.btnPx * (if b.primary then 1.4 else 1) + 3
		local row = rows[#rows]
		local need = if #row.items == 0 then w else row.w + z.ctlGap + w
		if #row.items > 0 and need > maxW then
			row = { items = {}, w = 0 }
			table.insert(rows, row)
			need = w
		end
		table.insert(row.items, { b = b, w = w })
		row.w = need
	end
	z.actRows = rows
	z.actsH = #rows * z.btnH + (#rows - 1) * z.ctlGap
	z.actsW = 0
	for _, r in rows do
		z.actsW = math.max(z.actsW, r.w)
	end
	z.opsW = 4 * z.opsz + 3 * z.ctlGap
	z.controlsH = 8 * f + z.opsz + z.ctlGap + z.actsH
	z.readout = readoutMetrics(f, L.playW - 44)
	z.eqH = z.ch + 6
	z.tableContent = z.tablePad * 2 + z.ch + z.eqH + z.readout.h + 2 * z.tableGap
	z.boardStatic = 0
	if L.skinny and V.boardShown then
		z.boardStatic = 18 + boardHeight()
	end
	z.natural = L.hm.h + 1 + z.tableContent + z.controlsH + z.boardStatic + 90
	z.handW = 4 * z.cw + 3 * z.handGap
	return z
end

-- the equation bar's items, left to right
local function eqSequence()
	local opens = table.clone(S.groups)
	table.sort(opens, function(a, b)
		if a.from ~= b.from then
			return a.from < b.from
		end
		return (a.to - a.from) > (b.to - b.from)
	end)
	local closes = table.clone(S.groups)
	table.sort(closes, function(a, b)
		if a.to ~= b.to then
			return a.to < b.to
		end
		return a.from > b.from
	end)
	local seq = {}
	if #S.eqItems == 0 then
		table.insert(seq, E.hint)
	end
	for i, tok in S.eqItems do
		for _, g in opens do
			if g.from == i then
				table.insert(seq, parenNodes(g).open)
			end
		end
		if tok.type == "card" then
			table.insert(seq, cardNodes[tok.id])
		else
			table.insert(seq, opNode(i, tok.op))
		end
		for _, g in closes do
			if g.to == i then
				table.insert(seq, parenNodes(g).close)
			end
		end
	end
	return seq
end

local function applyControlsLayout(z, f: number)
	local pad = 4
	local W = L.playW
	E.controls.Position = px(0, L.controlsTop - pad)
	E.controls.Size = px(W, z.controlsH + pad * 2)
	local y = 8 * f + pad
	local x = (W - z.opsW) / 2
	for _, b in E.opKeys do
		b.inst.Position = px(x, y)
		b.inst.Size = px(z.opsz, z.opsz)
		b.inst.TextSize = math.max(1, z.opsz * 0.45)
		b.corner.CornerRadius = UDim.new(0, z.opsz * 0.22)
		x += z.opsz + z.ctlGap
	end
	y += z.opsz + z.ctlGap
	for _, row in z.actRows do
		local rx = (W - row.w) / 2
		for _, it in row.items do
			local b = it.b
			b.inst.Position = px(rx, y)
			b.inst.Size = px(it.w, z.btnH)
			b.inst.TextSize = math.max(1, z.btnFs)
			b.corner.CornerRadius = UDim.new(0, 14 * f)
			rx += it.w + z.ctlGap
		end
		y += z.btnH + z.ctlGap
	end
end

local function applyHeaderLayout()
	local hm = L.hm
	local W = L.playW
	E.header.Position = px(0, 0)
	E.header.Size = px(W, hm.h + 1)
	E.rule.Position = px(0, hm.h)
	E.rule.Size = px(W, 1)
	local midY = hm.padT + hm.contentH / 2

	-- right side: quit, then stats right-to-left
	local x = W - hm.padX - 30
	E.quit.inst.Position = px(x, midY - 15)
	E.quit.inst.Size = px(30, 30)
	local statTop = midY - hm.statH / 2
	local order = { { E.bestStat, V.bestShown }, { E.timeStat, V.timeShown }, { E.solvedStat, true } }
	for _, pair in order do
		local st, shown = pair[1], pair[2]
		st.frame.Visible = shown
		if shown then
			local lw = Ui.textWidth(st.lbl.Text, hm.statLbl, "sans")
			local vw = Ui.textWidth(st.val.Text, hm.statVal, "serif", 700)
			local w = math.ceil(math.max(lw, vw)) + 2
			x -= hm.gap + w
			st.frame.Position = px(x, statTop)
			st.frame.Size = px(w, hm.statH)
			st.lbl.TextSize = hm.statLbl
			st.lbl.Size = px(w, hm.lblH)
			st.val.TextSize = hm.statVal
			st.val.Position = px(0, hm.lblH)
			st.val.Size = px(w, hm.valH)
			st.right = x + w
			st.top = statTop
		end
	end
	local statsLeft = x

	-- left: the "24" mark and the subtitle, baseline-aligned
	local markW = Ui.textWidth("24", hm.markFs, "serif", 700) + 2
	E.mark.TextSize = hm.markFs
	E.mark.Size = px(markW, hm.markFs * 1.25)
	E.mark.Position = px(hm.padX, midY - hm.markFs * 0.625)
	E.sub.Visible = hm.subShown
	local subX = hm.padX + markW + 10
	local baseline = midY + hm.markFs * 0.32
	E.sub.Position = px(subX, baseline - 12 * 1.05)
	E.sub.Size = px(math.max(0, statsLeft - 14 - subX), 12 * 1.3)
end

local function applyBoardLayout(z)
	if not V.boardShown then
		E.board.Visible = false
		return
	end
	local w = boardWidth()
	local h = boardHeight()
	local shift = if L.narrow then 42 else 0
	local x, y
	if L.skinny then
		w = math.min(L.playW, math.max(z.actsW, z.opsW))
		x = (L.playW - w) / 2
		y = L.controlsTop + z.controlsH + 18 + shift
	elseif V.boardCustom then
		x = clamp(0, V.boardCustom.X, math.max(0, L.playW - w))
		y = clamp(0, V.boardCustom.Y, math.max(0, L.H - h))
		V.boardCustom = V2(x, y)
	else
		x = L.playW - 16 - w
		y = L.hm.h + 1 + 12 + shift
	end
	E.boardBox = { x = x, y = y, w = w, h = h }
	E.board.Position = px(x, y)
	E.board.Size = px(w, h)
	local headH = 8 + 7 + 10.5 * 1.3
	E.boardHead.Size = px(w, headH)
	E.boardTitle.Position = px(12, 8)
	E.boardTitle.Size = px(w - 24, 10.5 * 1.3)
	local chevW = if L.skinny then 16 else 0
	E.boardClock.Position = px(12, 8)
	E.boardClock.Size = px(w - 24 - chevW, 10.5 * 1.3)
	E.boardClock.Text = V.boardClock
	E.boardChev.Visible = L.skinny
	E.boardChev.Position = px(w - 12 - 4, 8 + 10.5 * 0.65)
	E.boardDivider.Position = px(0, headH)
	E.boardDivider.Size = px(w, 1)
	E.boardRows.Visible = not (L.skinny and V.boardCollapsed)
	E.boardRows.Position = px(6, headH + 1 + 5)
	E.boardRows.Size = px(w - 12, V.boardRows * 25)
	for i, r in E.boardRowData or {} do
		r.frame.Position = px(0, (i - 1) * 25)
		r.frame.Size = px(w - 12, 25)
		r.name.Size = px(w - 12 - 12 - 14 - 8 - 8 - r.scoreW, 25)
		r.name.TextSize = if L.skinny then 11 else 12
		r.score.Position = px(w - 12 - 6 - r.scoreW, 0)
	end
end

local function applyVoteLayout(f: number)
	local vote = V.vote
	if not vote then
		E.votebar.Visible = false
		return
	end
	E.votebar.Visible = true
	local maxW = if L.skinny then 112 else 150
	local right = L.W - (if L.skinny then 6 else 10)
	local fs = if L.skinny then 10 else clamp(10, 1.5 * L.vh, 12.5) * f
	local padX, padY = if L.skinny then 8 else 10, if L.skinny then 5 else 6
	local innerMax = maxW - padX * 2
	local lines = {}
	local listW = 0
	local function addLine(text, bold, check)
		local indent = if check then fs * 0.95 else 0
		local tw = Ui.textWidth(text, fs, "sans", if bold then 600 else 400) + indent
		local w = math.min(innerMax, tw)
		local n = math.max(1, math.ceil(tw / innerMax - 0.02))
		table.insert(lines, { text = text, bold = bold, check = check, w = w, h = n * fs * 1.35, indent = indent })
		listW = math.max(listW, w)
	end
	addLine(vote.head, true, false)
	for _, name in vote.names do
		addLine(name, false, true)
	end
	local listH = padY * 2
	for i, ln in lines do
		listH += ln.h + (if i > 1 then 3 else 0)
	end
	listW += padX * 2

	-- vote button (white-space: nowrap, so it may be wider than the bar)
	local bfs, bpy, bpx
	if L.skinny then
		bfs, bpy, bpx = 11, 8, 10
	else
		local z = L.z
		bfs, bpy, bpx = z.btnFs * 0.82, z.btnPy * 0.72, z.btnPx
	end
	local bw = Ui.textWidth(E.voteBtn.inst.Text, bfs, "sans", 600) + bpx * 2 + 3
	local bh = bfs * 1.28 + bpy * 2 + 3
	local total = listH + 8 + bh
	local top = L.H / 2 - total / 2

	E.votebar.Position = px(0, 0)
	E.votebar.Size = px(0, 0)
	E.voteList.Position = px(right - listW, top)
	E.voteList.Size = px(listW, listH)
	for _, c in E.voteList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local y = padY
	for i, ln in lines do
		if i > 1 then
			y += 3
		end
		local lab = Ui.label({
			Text = ln.text,
			TextSize = fs,
			FontFace = Ui.sans(if ln.bold then 600 else 400),
			TextColor3 = if ln.bold then C.bone else C.bone,
			TextTransparency = if ln.bold then 0 else 0.08,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			LineHeight = 1.1,
			Position = px(padX, y),
			Size = px(listW - padX * 2, ln.h),
			ZIndex = 7,
			Parent = E.voteList,
		})
		if ln.check then
			lab.Size = px(listW - padX * 2, ln.h)
			local tw = math.min(ln.w, Ui.textWidth(ln.text, fs, "sans", 400))
			local mark = Ui.check(C.bone, 1.3, 7, 0.25)
			mark.Size = px(fs * 0.62, fs * 0.62)
			mark.Position = px(listW - padX - tw - fs * 0.9, y + fs * 0.3)
			mark.Parent = E.voteList
		end
		y += ln.h
	end
	E.voteBtn.inst.Position = px(right - bw, top + listH + 8)
	E.voteBtn.inst.Size = px(bw, bh)
	E.voteBtn.inst.TextSize = bfs
	E.voteBtn.corner.CornerRadius = UDim.new(0, 14 * L.fit)
	E.voteBtnBox = { x = right - bw, y = top + listH + 8, w = bw, h = bh }
end

local function applySolutionsLayout()
	local sol = E.sol
	sol.Visible = V.solShown
	if not V.solShown then
		return
	end
	local W, H = L.W, L.H
	local headPad = if L.narrow then 13 else 12
	local headPadX = if L.narrow then 16 else 14
	local titleH = 12.5 * 1.3
	local countH = 10.5 * 1.3
	local headH = headPad * 2 + titleH + 2 + countH
	local w = if L.narrow then W else L.solW
	local rowW = w - 24
	if E.solRowW ~= rowW then
		E.solRowW = rowW
		Play.fillSolutionsBody()
	end
	local bodyH = E.solBodyH or 0
	local x, y, h
	if L.narrow then
		-- sized to its content; collapsed, only the header strip shows
		local maxH = math.min(0.62 * H, 460)
		h = math.min(maxH, headH + bodyH)
		x = 0
		y = H - h + V.sheetOffset * (h - 48)
		E.solCorner.CornerRadius = UDim.new(0, 16)
		sol.BackgroundTransparency = 0.04
		E.solEdge.Position = px(0, 0)
		E.solEdge.Size = px(w, 1)
	else
		h = H
		x = L.playW
		y = 0
		E.solCorner.CornerRadius = UDim.new(0, 0)
		sol.BackgroundTransparency = 0.45
		E.solEdge.Position = px(0, 0)
		E.solEdge.Size = px(1, h)
	end
	-- rounded top only: extend the frame below the screen edge
	local extra = if L.narrow then 16 else 0
	sol.Position = px(x, y)
	sol.Size = px(w, h + extra)
	E.solBox = { x = x, y = y, w = w, h = h }
	E.solHead.Position = px(0, 0)
	E.solHead.Size = px(w, headH)
	E.solTitle.Position = px(headPadX, headPad)
	E.solTitle.Size = px(w - headPadX * 2 - 20, titleH)
	E.solCount.Position = px(headPadX, headPad + titleH + 2)
	E.solCount.Size = px(w - headPadX * 2 - 20, countH)
	E.solChev.Position = px(w - headPadX - 4, headH / 2)
	E.solHeadLine.Position = px(0, headH)
	E.solHeadLine.Size = px(w, 1)
	E.solBody.Visible = not V.solCollapsed or L.narrow
	E.solBody.Position = px(0, headH + 1)
	E.solBody.Size = px(w, math.max(0, h - headH - 1))
	E.solBody.CanvasSize = px(0, bodyH)
end

-- positions everything from the current state; cheap enough to call freely
function Play.layout()
	local root = E.root
	if not root then
		return
	end
	local size = root.AbsoluteSize
	if size.X < 10 or size.Y < 10 then
		return
	end
	local W, H = size.X, size.Y
	L.W, L.H = W, H
	L.vw, L.vh = W / 100, H / 100
	L.narrow = W <= 1023 or H <= 520
	L.skinny = W <= 760
	L.tiny = W <= 420
	L.solW = if V.solShown and not L.narrow then clamp(238, 24 * L.vw, 330) else 0
	L.playW = W - L.solW
	L.hm = headerMetrics(W, H)

	-- shrink --fit until the column (plus the 90px gap) fits
	local f = 1
	local z = sizesFor(f)
	local guard = 0
	while z.natural > H and f > 0.4 and guard < 30 do
		f = math.round((f - 0.04) * 100) / 100
		z = sizesFor(f)
		guard += 1
	end
	guard = 0
	while z.handW > (L.playW - 20) + 1 and f > 0.4 and guard < 30 do
		f = math.round((f - 0.04) * 100) / 100
		z = sizesFor(f)
		guard += 1
	end
	L.fit = f
	L.z = z

	-- vertical distribution (table flexes, bottom gap may shrink)
	local hm = L.hm
	local fixed = hm.h + 1 + z.controlsH + z.boardStatic
	local free = H - fixed - z.tableContent - 90
	local tableH
	if free >= 0 then
		tableH = z.tableContent + free
	else
		local over = -free
		local tot = z.tableContent + 90
		tableH = z.tableContent - over * z.tableContent / tot
	end
	local tableTop = hm.h + 1
	local contentTop = tableTop + (tableH - z.tableContent) / 2 + z.tablePad
	L.controlsTop = tableTop + tableH
	L.handCy = contentTop + z.ch / 2
	L.eqCy = contentTop + z.ch + z.tableGap + z.eqH / 2
	L.readoutTop = contentTop + z.ch + z.tableGap + z.eqH + z.tableGap

	applyHeaderLayout()

	-- hand slots
	local cx0 = L.playW / 2 - z.handW / 2 + z.cw / 2
	for i = 1, 4 do
		local slot = slotEls[i]
		slot.Position = px(cx0 + (i - 1) * (z.cw + z.handGap), L.handCy)
		slot.Size = px(z.cw, z.ch)
	end
	for _, n in cardNodes do
		sizeCard(n, z.cw, z.ch)
	end

	-- equation bar
	local seq = eqSequence()
	local inSeq = {}
	local total = 0
	for i, n in seq do
		inSeq[n] = true
		if n.kind == "card" then
			n.ew = z.cw
		elseif n.kind == "op" then
			local fs = z.ch * 0.38
			n.ew = Ui.textWidth(n.body.Text, fs, "serif", 600) + 2
			n:setBase(n.ew, fs * 1.35, fs)
		elseif n.kind == "paren" then
			local fs = z.ch * 0.92
			n.ew = Ui.textWidth(n.ch, fs, "serif", 400) + 6
			n:setBase(n.ew, fs * 1.35, fs)
		else
			local fs = 13
			n.ew = Ui.textWidth(n.body.Text, fs, "sans", 400) + 2
			n:setBase(n.ew, fs * 1.4, fs)
		end
		total += n.ew + (if i > 1 then z.eqGap else 0)
	end
	local avail = (L.playW - 20) - 16
	local eqScale = if total > avail and total > 0 and avail > 0 then math.max(0.35, avail / total) else 1
	L.eqScale = eqScale
	local x = L.playW / 2 - total * eqScale / 2
	for _, n in seq do
		n.inEq = true
		n.ls = eqScale
		n.cx = x + n.ew * eqScale / 2
		n.cy = L.eqCy
		n.holder.Visible = true
		x += (n.ew + z.eqGap) * eqScale
		n:apply()
	end
	for _, n in cardNodes do
		if not inSeq[n] then
			n.inEq = false
			n.ls = 1
			local slot = slotEls[n.id]
			n.cx = slot.Position.X.Offset
			n.cy = L.handCy
			n.holder.Visible = true
			n:apply()
		end
	end
	if not inSeq[E.hint] then
		E.hint.holder.Visible = false
		E.hint.inEq = false
	end
	L.seq = seq

	-- readout
	local rm = z.readout
	L.rm = rm
	E.readout.Position = px(0, L.readoutTop)
	E.readout.Size = px(L.playW, rm.h)
	local rt = E.readoutText
	rt.FontFace = if rm.family == "serif" then Ui.serif(600) else Ui.sans(500)
	rt.TextSize = math.max(1, rm.fs)
	rt.Text = V.readout.text
	local kind = V.readout.kind
	rt.TextColor3 = if kind == "good" then C.bone elseif kind == "bad" then C.bad else C.chalk
	local link = E.readoutLink
	link.Visible = rm.showLink
	link.TextSize = math.max(1, rm.lfs)
	local maxW = L.playW - 44
	if rm.oneLine or rm.lines == 0 then
		local tw = rm.tw + 2
		local startX = 22 + (maxW - (tw + rm.gap + rm.lw)) / 2
		rt.Position = px(startX, 0)
		rt.Size = px(tw, rm.h)
		link.Position = px(startX + tw + rm.gap, 0)
		link.Size = px(rm.lw, rm.h)
	else
		local textH = rm.textLines * rm.fs * 1.25
		rt.Position = px(22, 0)
		rt.Size = px(maxW, textH)
		link.Position = px(22 + (maxW - rm.lw) / 2, textH)
		link.Size = px(rm.lw, rm.lfs * 1.3)
	end
	Play.applyReadoutAlpha()

	applyControlsLayout(z, f)
	applyBoardLayout(z)
	applyVoteLayout(f)
	applySolutionsLayout()

	-- curtain covers the play column
	E.curtain.Size = px(L.playW, H)
	E.curtainWord.setSize(clamp(44, 13 * L.vw, 110))
	E.curtainWord.holder.Size = px(L.playW, clamp(44, 13 * L.vw, 110) * 1.4)
end

function Play.applyReadoutAlpha()
	local vis = (1 - V.readoutT) * (1 - V.phase3T)
	E.readoutText.TextTransparency = 1 - vis
	local linkVis = vis * (if E.readoutLinkHover then 0.8 else 1)
	E.readoutLink.TextTransparency = 1 - linkVis
end

local function applyEqAlpha()
	for _, n in L.seq or {} do
		if n.kind ~= "card" then
			n:applyAlpha()
		end
	end
	Play.applyReadoutAlpha()
end

---------------------------------------------------------------------------
-- render (FLIP)
---------------------------------------------------------------------------
local function capture()
	local m = {}
	for _, n in cardNodes do
		local x, y, s = n:visual()
		m[n] = { x = x, y = y, s = s }
	end
	for n in prevSeq do
		if n.kind ~= "card" and n.holder.Parent then
			local x, y, s = n:visual()
			m[n] = { x = x, y = y, s = s }
		end
	end
	return m
end

local function flipPlay(first)
	local targets = {}
	for _, n in cardNodes do
		targets[n] = true
	end
	for _, n in L.seq or {} do
		targets[n] = true
	end
	for n in targets do
		local f = first[n]
		if not f then
			if n.kind ~= "card" then
				-- pop in
				n:stop("flip")
				n:stop("pop")
				n.offX, n.offY = 0, 0
				n.anims.pop = Anim.run(0.15, Anim.EASE, function(e)
					n.pop = Anim.lerp(0.62, 1, e)
					n.alpha = 1 - e
					n:apply()
				end)
			end
			continue
		end
		local x, y, s = n.cx, n.cy, n.ls
		local dx, dy = f.x - x, f.y - y
		local sc = if s > 0 then f.s / s else 1
		if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 and math.abs(sc - 1) < 0.005 then
			continue
		end
		n:stop("flip")
		n:stop("pop")
		if n.kind ~= "card" then
			n.alpha = 0
		end
		n.offX, n.offY, n.pop = dx, dy, sc
		n:apply()
		n.anims.flip = Anim.run(0.2, Anim.EASE, function(e)
			n.offX = dx * (1 - e)
			n.offY = dy * (1 - e)
			n.pop = sc + (1 - sc) * e
			n:apply()
		end)
	end
end

local function cleanupCaches()
	for i, n in opCache do
		local tok = S.eqItems[i]
		if not tok or tok.type ~= "op" or tok.op ~= n.op then
			n:destroy()
			opCache[i] = nil
		end
	end
	for gid, p in parenCache do
		local alive = false
		for _, g in S.groups do
			if g.id == gid then
				alive = true
				break
			end
		end
		if not alive then
			p.open:destroy()
			p.close:destroy()
			parenCache[gid] = nil
		end
	end
end

function Play.render(animate: boolean?)
	local first = if animate == false then nil else capture()
	cleanupCaches()
	Play.syncControls(true)
	Play.layout()
	if first then
		flipPlay(first)
	end
	prevSeq = {}
	for _, n in L.seq or {} do
		prevSeq[n] = true
	end
end

function Play.syncControls(noLayout: boolean?)
	local n = Play.cardCount()
	local isMp = S.mode == "mp"
	local canOp = not S.locked and n > 0 and n < 4
	for _, b in E.opKeys do
		b.setDisabled(not canOp)
	end
	E.submitBtn.setDisabled(S.locked or n ~= 4)
	E.clearBtn.setDisabled(S.locked or #S.eqItems == 0)
	E.solutionBtn.inst.Visible = not isMp
	E.skipBtn.inst.Visible = not isMp
	if isMp then
		V.nextShown = false
	end
	E.nextBtn.inst.Visible = V.nextShown
	E.solutionBtn.setDisabled(S.locked)
	E.nextBtn.setDisabled(S.locked)
	E.skipBtn.setDisabled(S.locked)
	E.skipBtn.setText("Skip")
	if not noLayout then
		Play.layout()
	end
end

---------------------------------------------------------------------------
-- readout
---------------------------------------------------------------------------
local readoutToken = 0
local readoutAnim = nil

local function fadeReadout(show: boolean)
	if readoutAnim then
		readoutAnim:Cancel()
	end
	local from = V.readoutT
	local to = if show then 0 else 1
	if from == to then
		Play.applyReadoutAlpha()
		return
	end
	readoutAnim = Anim.run(0.12, Anim.CSS_EASE, function(e)
		V.readoutT = Anim.lerp(from, to, e)
		Play.applyReadoutAlpha()
	end)
end

function Play.say(text: string, kind: string?, withLink: boolean?)
	readoutToken += 1
	V.readout = { text = text, kind = kind, link = withLink and true or false, show = true }
	Play.layout()
	fadeReadout(true)
end

function Play.sayTemp(text: string, kind: string?, seconds: number?)
	Play.say(text, kind)
	local token = readoutToken
	task.delay(seconds or 1.2, function()
		if token == readoutToken then
			Play.clearSay()
		end
	end)
end

function Play.clearSay()
	readoutToken += 1
	if readoutAnim then
		readoutAnim:Cancel()
	end
	V.readoutT = 1
	V.readout = { text = "", kind = nil, link = false, show = false }
	Play.layout()
end

function Play.nudge()
	if E.nudgeAnim then
		E.nudgeAnim:Cancel()
	end
	E.nudgeAnim = Anim.run(0.3, Anim.EASE, function(e)
		V.shakeX = Anim.keyframes({ { 0, 0 }, { 0.28, -7 }, { 0.64, 6 }, { 1, 0 } }, e)
		for _, n in L.seq or {} do
			n:apply()
		end
	end, function()
		V.shakeX = 0
		for _, n in L.seq or {} do
			n:apply()
		end
	end)
end

---------------------------------------------------------------------------
-- equation editing (section 3 interactions)
---------------------------------------------------------------------------
function Play.cardCount(): number
	local c = 0
	for _, t in S.eqItems do
		if t.type == "card" then
			c += 1
		end
	end
	return c
end

local function groupContaining(i: number)
	for _, g in S.groups do
		if g.from <= i and i <= g.to then
			return g
		end
	end
	return nil
end

local function removeFrom(i: number)
	-- this card and everything to its right leaves the bar, along with the
	-- operator that joined it; any term it belonged to is dissolved
	local cut = i
	if cut > 1 and S.eqItems[cut - 1] and S.eqItems[cut - 1].type == "op" then
		cut -= 1
	end
	local items = {}
	for k = 1, cut - 1 do
		items[k] = S.eqItems[k]
	end
	S.eqItems = items
	local keep = {}
	for _, g in S.groups do
		if g.to < cut then
			table.insert(keep, g)
		end
	end
	S.groups = keep
	Play.clearSay()
	Play.render()
end

function Play.onCardClick(id: number)
	if S.locked or not clickOk() then
		return
	end
	for i, t in S.eqItems do
		if t.type == "card" and t.id == id then
			removeFrom(i) -- removal is silent
			return
		end
	end
	if Play.cardCount() >= 4 then
		return
	end
	local last = S.eqItems[#S.eqItems]
	Play.clearSay()
	if last and last.type == "card" then
		-- no operator chosen between two cards: default to addition
		table.insert(S.eqItems, { type = "op", op = "+" })
	end
	table.insert(S.eqItems, { type = "card", id = id })
	Sfx.add()
	Play.render()
end

function Play.onOpClick(op: string)
	if S.locked or not clickOk() then
		return
	end
	local n = Play.cardCount()
	if n == 0 then
		Play.sayTemp("put a card down first", "note", 1.1)
		Play.nudge()
		return
	end
	if n >= 4 then
		Play.sayTemp("all four cards are down \u{2014} hit submit", "note", 1.3)
		return
	end
	local last = S.eqItems[#S.eqItems]
	Play.clearSay()
	if last and last.type == "op" then
		last.op = op -- swap the pending operator
	else
		table.insert(S.eqItems, { type = "op", op = op })
	end
	Play.render()
end

function Play.clearEquation()
	if S.locked then
		return
	end
	S.eqItems = {}
	S.groups = {}
	Play.clearSay()
	Play.render()
end

function Play.removeGroup(gid: number)
	if S.locked or not clickOk() then
		return
	end
	local keep = {}
	for _, g in S.groups do
		if g.id ~= gid then
			table.insert(keep, g)
		end
	end
	S.groups = keep
	Play.render()
end

-- Removes the right-most element. A closing parenthesis counts as one
-- element: it takes its opener with it and leaves the term intact.
function Play.backspace()
	if S.locked or #S.eqItems == 0 then
		return
	end
	local lastIdx = #S.eqItems
	local ending = {}
	for _, g in S.groups do
		if g.to == lastIdx then
			table.insert(ending, g)
		end
	end
	if #ending > 0 then
		table.sort(ending, function(a, b)
			return a.from < b.from
		end)
		Play.removeGroupRaw(ending[1].id)
		return
	end
	table.remove(S.eqItems)
	local keep = {}
	for _, g in S.groups do
		if g.to <= #S.eqItems then
			table.insert(keep, g)
		end
	end
	S.groups = keep
	Play.clearSay()
	Play.render()
end

function Play.removeGroupRaw(gid: number)
	local keep = {}
	for _, g in S.groups do
		if g.id ~= gid then
			table.insert(keep, g)
		end
	end
	S.groups = keep
	Play.render()
end

-- display tokens for the current bar (also what gets sent to the server)
function Play.currentEqTokens()
	local opens = table.clone(S.groups)
	table.sort(opens, function(a, b)
		if a.from ~= b.from then
			return a.from < b.from
		end
		return (a.to - a.from) > (b.to - b.from)
	end)
	local closes = table.clone(S.groups)
	table.sort(closes, function(a, b)
		if a.to ~= b.to then
			return a.to < b.to
		end
		return a.from > b.from
	end)
	local out = {}
	for i, tok in S.eqItems do
		for _, g in opens do
			if g.from == i then
				table.insert(out, { type = "(" })
			end
		end
		if tok.type == "card" then
			table.insert(out, { type = "card", cardIdx = tok.id })
		else
			table.insert(out, { type = "op", op = tok.op })
		end
		for _, g in closes do
			if g.to == i then
				table.insert(out, { type = ")" })
			end
		end
	end
	return out
end

local function tokensToEquationState(tokens)
	local items, grps, stack = {}, {}, {}
	for _, tok in tokens do
		if tok.type == "(" then
			table.insert(stack, #items + 1)
		elseif tok.type == ")" then
			local from = table.remove(stack)
			table.insert(grps, { id = S.groupSeq, from = from, to = #items })
			S.groupSeq += 1
		elseif tok.type == "card" then
			table.insert(items, { type = "card", id = tok.cardIdx })
		else
			table.insert(items, { type = "op", op = tok.op })
		end
	end
	return items, grps
end

---------------------------------------------------------------------------
-- drag selection -> parentheses (section 4)
---------------------------------------------------------------------------
local function overlaps(r1, r)
	return not (r1.right < r.left or r1.left > r.right or r1.bottom < r.top or r1.top > r.bottom)
end

function Play.applySelection(r)
	if S.locked then
		return
	end
	local hits = {}
	for i, tok in S.eqItems do
		if tok.type == "card" and overlaps(cardNodes[tok.id]:rect(), r) then
			table.insert(hits, i)
		end
	end
	if #hits == 0 then
		return
	end

	-- a term spanning all four cards can never be bracketed: selecting
	-- everything just wipes every existing group instead
	if #hits == 4 then
		if #S.groups > 0 then
			S.groups = {}
			Play.render()
		end
		return
	end

	local from, to = hits[1], hits[#hits]
	local function without(id)
		local keep = {}
		for _, g in S.groups do
			if g.id ~= id then
				table.insert(keep, g)
			end
		end
		S.groups = keep
	end
	local function push(a, b)
		table.insert(S.groups, { id = S.groupSeq, from = a, to = b })
		S.groupSeq += 1
	end

	-- a nested term is an inner group strictly inside an outer one;
	-- touching any part of it clears the outer, and re-selecting exactly its
	-- three cards collapses the inner too
	local nestedOuter, nestedInner = nil, nil
	for _, g in S.groups do
		for _, h in S.groups do
			if g ~= h and h.from >= g.from and h.to <= g.to and (h.from > g.from or h.to < g.to) then
				nestedOuter, nestedInner = g, h
			end
		end
	end
	if nestedOuter and not (from > nestedOuter.to or to < nestedOuter.from) then
		without(nestedOuter.id)
		if from == nestedOuter.from and to == nestedOuter.to then
			without(nestedInner.id)
			push(from, to)
			Play.render()
			return
		end
		if #hits == 1 then
			Play.render()
			return
		end
	end

	if #hits == 1 then
		local g = groupContaining(hits[1])
		if g then
			without(g.id)
			Play.render()
		end
		return
	end

	-- three cards, two already grouped: nest a new outer term around them
	if #hits == 3 then
		local inside = {}
		for _, x in S.groups do
			if x.from >= from and x.to <= to then
				table.insert(inside, x)
			end
		end
		if #inside == 1 and (inside[1].to - inside[1].from) < (to - from) then
			push(from, to)
			Play.render()
			return
		end
	end

	-- a new term replaces any term it touches
	local keep = {}
	for _, x in S.groups do
		if x.to < from or x.from > to then
			table.insert(keep, x)
		end
	end
	S.groups = keep
	-- wrapping the whole bar only makes no sense once 3+ cards are down
	local wrapsAll = from == 1 and to == #S.eqItems and Play.cardCount() > 2
	if not wrapsAll then
		push(from, to)
	end
	Play.clearSay()
	Play.render()
	if wrapsAll then
		Play.sayTemp("the whole equation is already one term", "note", 1.3)
	end
end

local function inBox(p: Vector2, b): boolean
	return b ~= nil and p.X >= b.x and p.X <= b.x + b.w and p.Y >= b.y and p.Y <= b.y + b.h
end

local function toRoot(pos: Vector3 | Vector2): Vector2
	local ap = E.root.AbsolutePosition
	return V2(pos.X - ap.X, pos.Y - ap.Y)
end

local drag = nil

function Play.initInput()
	UserInputService.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
			return
		end
		if S.locked or Play.hooks.isOverlayVisible() or drag then
			return
		end
		if not E.header.Visible then
			return
		end
		local p = toRoot(input.Position)
		if p.X > L.playW or p.X < 0 or p.Y < 0 or p.Y > L.H then
			return
		end
		if V.boardShown and inBox(p, E.boardBox) then
			return
		end
		if V.solShown and inBox(p, E.solBox) then
			return
		end
		drag = { input = input, touch = t == Enum.UserInputType.Touch, x = p.X, y = p.Y }
		S.dragging = false
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not drag then
			return
		end
		if drag.touch then
			if input ~= drag.input then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local p = toRoot(input.Position)
		local dx, dy = p.X - drag.x, p.Y - drag.y
		if not S.dragging and math.sqrt(dx * dx + dy * dy) < 7 then
			return
		end
		S.dragging = true
		local sb = E.selbox
		sb.Visible = true
		sb.Position = px(math.min(drag.x, p.X), math.min(drag.y, p.Y))
		sb.Size = px(math.abs(dx), math.abs(dy))
		drag.lx, drag.ly = p.X, p.Y
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not drag then
			return
		end
		if drag.touch then
			if input ~= drag.input then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local d = drag
		drag = nil
		E.selbox.Visible = false
		if not S.dragging then
			return
		end
		local p = toRoot(input.Position)
		S.suppressUntil = os.clock() + 0.1
		task.defer(function()
			S.dragging = false
		end)
		Play.applySelection({
			left = math.min(d.x, p.X),
			right = math.max(d.x, p.X),
			top = math.min(d.y, p.Y),
			bottom = math.max(d.y, p.Y),
		})
	end)

	-- keyboard: mirrors the on-screen controls exactly
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if Play.hooks.isOverlayVisible() or S.locked then
			return
		end
		local kc = input.KeyCode
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if kc == Enum.KeyCode.Backspace then
			Play.backspace()
			return
		end
		if kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then
			if not E.submitBtn.disabled then
				Play.onSubmit()
			end
			return
		end
		local op = nil
		if kc == Enum.KeyCode.KeypadPlus or (kc == Enum.KeyCode.Equals and shift) or kc == Enum.KeyCode.Plus then
			op = "+"
		elseif kc == Enum.KeyCode.Minus or kc == Enum.KeyCode.KeypadMinus then
			op = "-"
		elseif kc == Enum.KeyCode.Slash or kc == Enum.KeyCode.KeypadDivide then
			op = "/"
		elseif
			kc == Enum.KeyCode.X
			or kc == Enum.KeyCode.KeypadMultiply
			or kc == Enum.KeyCode.Asterisk
			or (kc == Enum.KeyCode.Eight and shift)
		then
			op = "*"
		end
		if op then
			-- nothing happens unless the operator keys are live
			if E.opKeys[1].disabled then
				return
			end
			Play.onOpClick(op)
		end
		local _ = processed
	end)
end

function Play.initBoardDrag()
	local head = E.boardHead
	local bdrag = nil
	head.Activated:Connect(function()
		if not L.skinny then
			return
		end
		V.boardCollapsed = not V.boardCollapsed
		Ui.tween(E.boardChev, 0.16, { Rotation = if V.boardCollapsed then 0 else 90 })
		Play.layout()
	end)
	head.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if L.skinny or (t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch) then
			return
		end
		local p = toRoot(input.Position)
		local b = E.boardBox
		if not b then
			return
		end
		bdrag = { input = input, touch = t == Enum.UserInputType.Touch, ox = p.X - b.x, oy = p.Y - b.y }
		V.boardCustom = V2(b.x, b.y)
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not bdrag then
			return
		end
		if bdrag.touch then
			if input ~= bdrag.input then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local p = toRoot(input.Position)
		V.boardCustom = V2(p.X - bdrag.ox, p.Y - bdrag.oy)
		applyBoardLayout(L.z)
	end)
	UserInputService.InputEnded:Connect(function(input)
		if not bdrag then
			return
		end
		if bdrag.touch and input ~= bdrag.input then
			return
		end
		if not bdrag.touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		bdrag = nil
	end)
end

---------------------------------------------------------------------------
-- submission / progression
---------------------------------------------------------------------------
function Play.ensureSolutionCache()
	if not S.solutionCache then
		local trees = Solver.uniqueSolutions(S.puzzle)
		S.solutionCache = { trees = trees, count = #trees }
	end
	return S.solutionCache
end

function Play.onSubmit()
	if S.locked or Play.cardCount() ~= 4 then
		return
	end
	Sfx.submit()
	local toks = Play.currentEqTokens()
	local val = Solver.evaluate(toks, S.puzzle)
	if val == nil then
		Play.say("that one won't evaluate \u{2014} check the division", "bad")
		Play.nudge()
		return
	end
	local correct = Solver.is24(val)

	if S.mode == "mp" then
		if not correct then
			Play.say("= " .. Solver.ratText(val) .. " \u{00B7} not 24", "bad")
			Play.nudge()
			return
		end
		Play.hooks.onMpClaim(toks)
		return
	end

	if correct then
		local firstTime = not S.puzzleSolved
		S.puzzleSolved = true
		S.canShowOthers = true
		V.nextShown = true
		if firstTime then
			Play.onSolved()
		end
		local n = Play.ensureSolutionCache().count
		if n > 1 then
			Play.say("= 24 \u{00B7} solved \u{2014} " .. n .. " non-identical solutions in total \u{00B7} ", "good", true)
		else
			Play.say("= 24 \u{00B7} solved \u{2014} this is the only solution \u{00B7} ", "good", false)
		end
		Play.syncControls()
	else
		Play.say("= " .. Solver.ratText(val) .. " \u{00B7} not 24 yet", "bad")
		Play.nudge()
	end
end

function Play.onSolutionClick()
	if S.locked or not clickOk() then
		return
	end
	local cache = Play.ensureSolutionCache()
	if cache.count == 0 then
		Play.sayTemp("no solution for this hand", nil, 1.4)
		return
	end
	S.eqItems, S.groups = tokensToEquationState(Solver.treeToTokens(cache.trees[1]))
	Play.render()
	local n = cache.count
	Play.say(
		n
			.. " non-identical solution"
			.. (if n == 1 then "" else "s")
			.. " \u{2014} one shown above"
			.. (if S.canShowOthers then " \u{00B7} " else ""),
		nil,
		true
	)
end

function Play.bumpSolved()
	S.solved += 1
	E.solvedStat.val.Text = tostring(S.solved)
	Play.layout()
	local st = E.solvedStat
	local pop = Ui.label({
		Text = "+1",
		TextSize = 12,
		FontFace = Ui.sans(600),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 6,
		Size = px(30, 14),
		Parent = E.pops,
	})
	local baseX = (st.right or 0) + 14 - 30
	local baseY = (st.top or 0) - 4
	Anim.run(0.85, Anim.CSS_EASE, function(_, p)
		local y = Anim.keyframes({ { 0, 5 }, { 0.22, 0 }, { 1, -15 } }, p)
		local o = Anim.keyframes({ { 0, 0 }, { 0.22, 1 }, { 1, 0 } }, p)
		pop.Position = px(baseX, baseY + y)
		pop.TextTransparency = 1 - o
	end, function()
		pop:Destroy()
	end)
end

function Play.onSolved()
	Play.bumpSolved()
	if S.mode == "solo" then
		if S.solved > S.best then
			Play.setBest(S.solved)
		end
		Play.hooks.onSoloSolved()
	end
end

function Play.setBest(n: number)
	S.best = n
	E.bestStat.val.Text = tostring(n)
	Play.layout()
end

function Play.setSolved(n: number)
	S.solved = n
	E.solvedStat.val.Text = tostring(n)
	Play.layout()
end

---------------------------------------------------------------------------
-- solutions panel
---------------------------------------------------------------------------
function Play.miniSize(): (number, number)
	if L.tiny then
		return 22, 31
	end
	return 26, 36
end

-- one miniature card (solutions panel, round log)
function Play.miniCard(c, parent: Instance?)
	local mcw, mch = Play.miniSize()
	local red = Solver.SUIT_RED[c.s] or false
	local color = if red then C.rouge else C.ink
	local f = Ui.frame({
		Name = "MiniCard",
		BackgroundTransparency = 0,
		BackgroundColor3 = C.bone,
		Size = px(mcw, mch),
		Parent = parent,
	})
	Ui.corner(f, 4)
	Ui.stroke(f, C.black, 0.7, 1)
	Ui.label({
		Text = Solver.rankLabel(c.v),
		FontFace = Ui.serif(700),
		TextSize = mch * 0.40,
		TextColor3 = color,
		Position = px(0, mch * 0.38 - mch * 0.26),
		Size = px(mcw, mch * 0.52),
		Parent = f,
	})
	local s = Ui.suit(c.s, color)
	s.AnchorPoint = V2(0.5, 0.5)
	s.Size = px(mch * 0.2, mch * 0.2)
	s.Position = px(mcw / 2, mch * 0.71)
	s.Parent = f
	return f
end

-- mini equation row (shared with the round-by-round log)
function Play.miniRow(toks, cards, label: string?, width: number)
	local mcw, mch = Play.miniSize()
	local row = Ui.frame({
		Name = "SolRow",
		BackgroundTransparency = 0.9,
		BackgroundColor3 = C.white,
		Size = px(width, 0),
	})
	Ui.corner(row, 10)
	Ui.stroke(row, C.white, 0.86, 1)
	local innerW = width - 18
	local y = 8
	if label then
		Ui.label({
			Text = label,
			TextSize = 9.5,
			TextColor3 = C.chalk,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = px(9, y),
			Size = px(innerW, 12.4),
			Parent = row,
		})
		y += 12.4 + 3 + 4
	end
	local items = {}
	for _, t in toks do
		if t.type == "card" then
			local c = cards[t.cardIdx]
			if c then
				local f = Play.miniCard(c, row)
				table.insert(items, { f = f, w = mcw, h = mch })
			end
		elseif t.type == "op" then
			local fs = mch * 0.46
			local w = Ui.textWidth(Solver.GLYPH[t.op], fs, "serif", 600) + 2
			local f = Ui.label({
				Text = Solver.GLYPH[t.op],
				FontFace = Ui.serif(600),
				TextSize = fs,
				Size = px(w, fs),
				Parent = row,
			})
			table.insert(items, { f = f, w = w, h = fs })
		else
			local fs = mch * 0.95
			local ch = if t.type == "(" then "(" else ")"
			local w = Ui.textWidth(ch, fs, "serif", 400) + 2
			local f = Ui.label({
				Text = ch,
				FontFace = Ui.serif(400),
				TextSize = fs,
				Size = px(w, fs * 0.7),
				Parent = row,
			})
			table.insert(items, { f = f, w = w, h = fs * 0.7 })
		end
	end
	-- flex-wrap with a 4px gap
	local lines = { { items = {}, w = 0, h = 0 } }
	for _, it in items do
		local line = lines[#lines]
		local need = if #line.items == 0 then it.w else line.w + 4 + it.w
		if #line.items > 0 and need > innerW then
			line = { items = {}, w = 0, h = 0 }
			table.insert(lines, line)
			need = it.w
		end
		table.insert(line.items, it)
		line.w = need
		line.h = math.max(line.h, it.h)
	end
	for li, line in lines do
		local x = 9
		for _, it in line.items do
			it.f.Position = px(x, y + (line.h - it.h) / 2)
			x += it.w + 4
		end
		y += line.h + (if li < #lines then 4 else 0)
	end
	local h = y + 8
	row.Size = px(width, h)
	return row, h
end

function Play.fillSolutionsBody()
	local body = E.solBody
	for _, c in body:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local cache = S.solutionCache
	if not V.solShown or not cache then
		E.solBodyH = 0
		return
	end
	local w = E.solRowW or 200
	local y = 10
	for i, tree in cache.trees do
		local row, h = Play.miniRow(Solver.treeToTokens(tree), S.puzzle, "#" .. i, w)
		row.Position = px(12, y)
		row.ZIndex = 22
		row.Parent = body
		y += h + 9
	end
	E.solBodyH = y - 9 + 16
	body.CanvasSize = px(0, E.solBodyH)
end

function Play.openSolutionsPanel()
	local cache = Play.ensureSolutionCache()
	if cache.count == 0 then
		return
	end
	V.solShown = true
	V.solCollapsed = false
	V.sheetOffset = 0
	E.solCount.Text = cache.count .. " distinct way" .. (if cache.count == 1 then "" else "s") .. " to make 24"
	E.solChev.Rotation = 90
	E.solRowW = nil -- forces a refill at the right width
	E.solBody.CanvasPosition = V2(0, 0)
	Play.layout()
end

function Play.hideSolutionsPanel()
	V.solShown = false
	V.solCollapsed = false
	V.sheetOffset = 0
	if E.sheetAnim then
		E.sheetAnim:Cancel()
	end
	if E.solBody then
		for _, c in E.solBody:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end
	E.solBodyH = 0
	E.solRowW = nil
end

function Play.toggleSolutionsPanel()
	V.solCollapsed = not V.solCollapsed
	Ui.tween(E.solChev, 0.16, { Rotation = if V.solCollapsed then 0 else 90 })
	if L.narrow then
		if E.sheetAnim then
			E.sheetAnim:Cancel()
		end
		local from = V.sheetOffset
		local to = if V.solCollapsed then 1 else 0
		E.sheetAnim = Anim.run(0.22, Anim.EASE, function(e)
			V.sheetOffset = Anim.lerp(from, to, e)
			applySolutionsLayout()
		end)
	end
	Play.layout()
end

---------------------------------------------------------------------------
-- dealing (section 5)
---------------------------------------------------------------------------
local DEAL_STAGGER = 0.105
local DEAL_FLIGHT = 0.36
function Play.dealDuration(): number
	return DEAL_STAGGER * 3 + DEAL_FLIGHT + 0.04
end

local dealGen = 0

function Play.animateDeal()
	dealGen += 1
	local gen = dealGen
	for i, n in cardNodes do
		n:stop("flip")
		n:stop("deal")
		-- start above the top edge, horizontally centred on the window
		local dx = L.W / 2 - n.cx
		local dy = -(n.cy + n.h / 2 + 60 + 60)
		local tilt = (i - 2.5) * 3.5
		n.offX, n.offY, n.rot, n.pop, n.alpha = dx, dy, tilt, 0.92, 1
		n:apply()
		n.anims.deal = Anim.run(DEAL_FLIGHT, Anim.LINEAR, function(_, p)
			local e = Anim.DEAL(p)
			n.offX = dx * (1 - e)
			n.offY = dy * (1 - e)
			n.rot = tilt * (1 - e)
			n.pop = 0.92 + 0.08 * e
			n.alpha = 1 - math.clamp(p * DEAL_FLIGHT / 0.15, 0, 1)
			n:apply()
		end, function()
			n.offX, n.offY, n.rot, n.pop, n.alpha = 0, 0, 0, 1, 0
			n:apply()
		end, (i - 1) * DEAL_STAGGER)
		task.delay((i - 1) * DEAL_STAGGER, function()
			if gen == dealGen then
				Sfx.deal()
			end
		end)
	end
end

function Play.fadeOutHand(done)
	local list = {}
	for _, n in cardNodes do
		table.insert(list, n)
	end
	if #list == 0 then
		done()
		return
	end
	for _, n in list do
		n:stop("deal")
		n.body.Interactable = false
		local from = n.alpha
		n.anims.fade = Anim.run(0.13, Anim.LINEAR, function(e)
			n.alpha = from + (1 - from) * e
			n:applyAlpha()
		end)
	end
	task.delay(0.14, done)
end

function Play.dealNew(cardsData, opts)
	opts = opts or {}
	dealGen += 1
	S.puzzle = cardsData or Solver.generatePuzzle()
	S.eqItems = {}
	S.groups = {}
	S.locked = opts.locked and true or false
	S.solutionCache = nil
	S.puzzleSolved = false
	S.canShowOthers = false
	V.nextShown = false
	Play.hideSolutionsPanel()
	if not opts.keepSay then
		V.readout = { text = "", kind = nil, link = false, show = false }
		V.readoutT = 1
		readoutToken += 1
	end
	-- rebuild the hand
	for _, n in cardNodes do
		n:destroy()
	end
	cardNodes = {}
	for i, n in opCache do
		n:destroy()
		opCache[i] = nil
	end
	for gid, p in parenCache do
		p.open:destroy()
		p.close:destroy()
		parenCache[gid] = nil
	end
	prevSeq = {}
	for i, c in S.puzzle do
		cardNodes[i] = makeCard(i, c)
	end
	Play.syncControls(true)
	Play.layout()
	prevSeq = {}
	for _, n in L.seq or {} do
		prevSeq[n] = true
	end
	if opts.deal ~= false then
		Play.animateDeal()
	else
		for _, n in cardNodes do
			n.alpha = 1
			n:apply()
		end
	end
end

-- fades the old hand away, then deals the replacement
function Play.replaceHand(cardsData, opts)
	Play.fadeOutHand(function()
		Play.dealNew(cardsData, opts)
	end)
end

function Play.advancePuzzle()
	if S.mode == "mp" then
		return
	end
	Play.replaceHand(nil)
end

function Play.setLocked(v: boolean)
	S.locked = v
	Play.syncControls()
end

---------------------------------------------------------------------------
-- staged entrance / exit
---------------------------------------------------------------------------
local function slideIn(group: CanvasGroup, fromDy: number, baseY: number)
	group.Visible = true
	group.GroupTransparency = 1
	Anim.run(0.42, Anim.LINEAR, function(_, p)
		local e = Anim.EASE(p)
		group.GroupTransparency = 1 - e
		group.Position = UDim2.fromOffset(group.Position.X.Offset, baseY + fromDy * (1 - e))
	end, function()
		Play.layout()
	end)
end

-- Phase 2: HUD slides down and the hand's grey slots fade in
function Play.revealHud()
	V.hudHidden = false
	Play.layout()
	slideIn(E.header, -22, 0)
	Anim.run(0.36, Anim.CSS_EASE, function(e)
		for _, s in slotEls do
			s.BackgroundTransparency = 1 - 0.2 * e
		end
	end)
end

-- Phase 3: buttons, standings and the equation bar appear
function Play.revealRest()
	V.restHidden = false
	Play.layout()
	slideIn(E.controls, 22, E.controls.Position.Y.Offset)
	if V.boardShown then
		E.board.Visible = true
		E.board.GroupTransparency = 1
		Anim.run(0.36, Anim.CSS_EASE, function(e)
			E.board.GroupTransparency = 1 - e
		end)
	end
	Anim.run(0.36, Anim.CSS_EASE, function(e)
		V.phase3T = 1 - e
		applyEqAlpha()
	end)
end

function Play.leavePlay()
	S.locked = true
	dealGen += 1
	E.curtain.Visible = false
	V.curtainShown = false
	V.boardShown = false
	V.nextShown = false
	Play.hideVote()
	Play.hideSolutionsPanel()
	V.readout = { text = "", kind = nil, link = false, show = false }
	V.readoutT = 1
	readoutToken += 1
	V.hudHidden = true
	V.restHidden = true
	V.phase3T = 1
	E.header.Visible = false
	E.controls.Visible = false
	E.board.Visible = false
	for _, s in slotEls do
		s.BackgroundTransparency = 1
	end
	for _, n in cardNodes do
		n:stop("deal")
		n.alpha = 1
		n:apply()
	end
	Play.syncControls()
	applyEqAlpha()
end

---------------------------------------------------------------------------
-- chrome for each mode
---------------------------------------------------------------------------
function Play.applySoloChrome()
	S.mode = "solo"
	V.bestShown = true
	V.timeShown = false
	V.boardShown = false
	V.vote = nil
	E.sub.Text = "use all four cards, once each"
	Play.layout()
end

function Play.applyMpChrome(target: number)
	S.mode = "mp"
	V.bestShown = false
	V.timeShown = true
	E.timeStat.lbl.Text = "to win"
	E.timeStat.val.Text = tostring(target)
	V.boardShown = true
	V.boardClock = "first to " .. target
	E.sub.Text = "first correct answer takes the hand"
	Play.layout()
end

function Play.clearModeChrome()
	S.mode = nil
	V.boardShown = false
	V.timeShown = false
	E.timeStat.lbl.Text = "time"
	Play.hideVote()
	Play.layout()
end

function Play.setMode(m)
	S.mode = m
end

---------------------------------------------------------------------------
-- standings + votes
---------------------------------------------------------------------------
function Play.renderBoard(players, meId: number)
	for _, c in E.boardRows:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local data = {}
	for i, p in players do
		if i > 8 then
			break
		end
		local isMe = p.id == meId
		local lead = i == 1 and (p.score or 0) > 0
		local fade = if p.stale then 0.45 else 0
		local fs = if L.skinny then 11 else 12
		local rowF = Ui.frame({
			BackgroundTransparency = if isMe then 0.84 else 1,
			BackgroundColor3 = C.bone,
			ZIndex = 4,
			Parent = E.boardRows,
		})
		Ui.corner(rowF, 7)
		Ui.label({
			Text = tostring(i),
			TextSize = 10,
			TextColor3 = if isMe then C.bone else C.chalk,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTransparency = fade,
			Position = px(6, 0),
			Size = px(14, 25),
			ZIndex = 4,
			Parent = rowF,
		})
		local name = Ui.label({
			Text = p.name or "player",
			TextSize = fs,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextTransparency = fade,
			Position = px(28, 0),
			ZIndex = 4,
			Parent = rowF,
		})
		local scoreText = tostring(p.score or 0)
		local scoreW = Ui.textWidth(scoreText, 15, "serif", 700) + 2
		local score = Ui.label({
			Text = if lead then "<u>" .. scoreText .. "</u>" else scoreText,
			RichText = true,
			FontFace = Ui.serif(700),
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTransparency = fade,
			Size = px(scoreW, 25),
			ZIndex = 4,
			Parent = rowF,
		})
		table.insert(data, {
			frame = rowF,
			name = name,
			score = score,
			scoreW = scoreW,
			nameW = Ui.textWidth(p.name or "player", fs, "sans"),
		})
	end
	E.boardRowData = data
	V.boardRows = #data
	Play.layout()
end

function Play.hideVote()
	V.vote = nil
	if E.votebar then
		E.votebar.Visible = false
	end
end

function Play.showVote(head: string, names, iVoted: boolean)
	V.vote = { head = head, names = names, iVoted = iVoted }
	E.voteBtn.setStyle(if iVoted then "voteCast" else "vote")
	E.voteBtn.setDisabled(iVoted)
	E.voteBtn.setText(if iVoted then "Vote cast" else "Vote to skip this hand")
	Play.layout()
end

---------------------------------------------------------------------------
-- ready / set / go
---------------------------------------------------------------------------
function Play.runCurtain(duration: number)
	local cur = E.curtain
	cur.Visible = true
	cur.BackgroundTransparency = 0
	local word = E.curtainWord
	local t0 = os.clock()
	local beatAnim = nil
	local function beat(text)
		word.label.Text = text
		if beatAnim then
			beatAnim:Cancel()
		end
		local baseSize = word.size
		beatAnim = Anim.run(0.52, Anim.LINEAR, function(_, p)
			local e = Anim.EASE(p)
			local s = Anim.keyframes({ { 0, 0.72 }, { 0.45, 1.06 }, { 1, 1 } }, e)
			local o = Anim.keyframes({ { 0, 0 }, { 0.45, 1 }, { 1, 1 } }, e)
			word.setSize(baseSize * s)
			word.label.TextTransparency = 1 - o
		end, function()
			word.setSize(baseSize)
		end)
	end
	local function left()
		return duration - (os.clock() - t0)
	end
	Play.layout()
	if duration < 2.2 then
		beat("Go")
		task.wait(math.max(0, left()))
	else
		beat("Ready")
		task.wait(math.max(0, left() - 1.65))
		beat("Set")
		task.wait(math.max(0, left() - 0.85))
		beat("Go")
		task.wait(math.max(0, left()))
	end
	if beatAnim then
		beatAnim:Cancel()
	end
	Play.layout()
	Anim.run(0.3, Anim.CSS_EASE, function(e)
		cur.BackgroundTransparency = e
		word.label.TextTransparency = e
	end)
	task.wait(0.3)
	cur.Visible = false
end

return Play

--[[
	Menus — the overlay: main menu, how it works, create / join, the lobby,
	the end screen (with the round-by-round log) and "the host left".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("TwentyFour")
local Solver = require(Shared:WaitForChild("Solver"))
local Ui = require(script.Parent:WaitForChild("Ui"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local Play = require(script.Parent:WaitForChild("Play"))

local C = Ui.C
local px = UDim2.fromOffset
local AUTO_Y = Enum.AutomaticSize.Y

local Menus = {}
Menus.hooks = {} -- filled by the flow controller
Menus.current = nil

local M = {} -- elements
local panels = {}

local function hook(name: string, ...)
	local fn = Menus.hooks[name]
	if fn then
		task.spawn(fn, ...)
	end
end

---------------------------------------------------------------------------
-- panel builder
---------------------------------------------------------------------------
local Panel = {}
Panel.__index = Panel

local function newPanel(name: string, wide: boolean?)
	local inst = Ui.new("CanvasGroup", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutomaticSize = AUTO_Y,
		Size = px(420, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		Parent = M.wrap,
	})
	Ui.new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = inst,
	})
	if not wide then
		Ui.new("UIPadding", {
			PaddingLeft = UDim.new(0, 22),
			PaddingRight = UDim.new(0, 22),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
			Parent = inst,
		})
	end
	local p = setmetatable({ inst = inst, wide = wide, order = 0, name = name }, Panel)
	panels[name] = p
	inst:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Menus.current == name then
			Menus.layout()
		end
	end)
	return p
end

function Panel:add(inst, parent)
	self.order += 1
	inst.LayoutOrder = self.order
	inst.Parent = parent or self.inst
	return inst
end

function Panel:gap(h: number, parent)
	return self:add(Ui.frame({ Name = "Gap", Size = UDim2.new(1, 0, 0, h) }), parent)
end

function Panel:text(t: string, o, parent)
	o = o or {}
	local l = Ui.label({
		Text = t,
		TextSize = o.size or 13.5,
		TextColor3 = o.color or C.chalk,
		FontFace = o.font or Ui.sans(400),
		TextWrapped = true,
		RichText = o.rich or false,
		LineHeight = o.lh or 1,
		TextXAlignment = o.align or Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, o.minH or 0),
		AutomaticSize = AUTO_Y,
	})
	return self:add(l, parent)
end

function Panel:h1(t: string)
	local l = self:text(t, { size = 30, color = C.bone, font = Ui.serif(700) })
	self:gap(10)
	return l
end

function Panel:kicker(t: string)
	local l = self:text(t, { size = 12, color = C.chalk })
	self:gap(12)
	return l
end

function Panel:para(t: string)
	local l = self:text(t, { size = 13.5, color = C.chalk, lh = 1.35 })
	self:gap(10)
	return l
end

function Panel:rules(rich: string)
	self:gap(16)
	local box = Ui.frame({
		Name = "Rules",
		BackgroundTransparency = 0.84,
		BackgroundColor3 = C.black,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = AUTO_Y,
	})
	Ui.corner(box, 12)
	Ui.stroke(box, C.bone, Ui.LINE_T, 1)
	Ui.new("UIPadding", {
		PaddingTop = UDim.new(0, 13),
		PaddingBottom = UDim.new(0, 13),
		PaddingLeft = UDim.new(0, 17),
		PaddingRight = UDim.new(0, 17),
		Parent = box,
	})
	local l = Ui.label({
		Text = rich,
		RichText = true,
		TextSize = 12.5,
		TextColor3 = C.chalk,
		TextWrapped = true,
		LineHeight = 1.45,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = AUTO_Y,
		Parent = box,
	})
	self:add(box)
	self:gap(16)
	return box, l
end

function Panel:go(label: string, ghost: boolean?, onClick, marginTop: number?)
	self:gap(marginTop or 9)
	local b = Ui.button({
		Name = label,
		style = if ghost then "ghost" else "go",
		Text = label,
		FontFace = Ui.sans(600),
		TextSize = 13.5,
		radius = 12,
		onClick = onClick,
	})
	b.inst.Size = UDim2.new(1, 0, 0, 47)
	self:add(b.inst)
	return b
end

function Panel:tiny(label: string, onClick, marginTop: number?)
	local holder = Ui.frame({ Name = "Tiny", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y })
	Ui.new("UIPadding", { PaddingTop = UDim.new(0, marginTop or 15), Parent = holder })
	local b = Ui.new("TextButton", {
		Text = "<u>" .. Ui.escape(label) .. "</u>",
		RichText = true,
		FontFace = Ui.sans(400),
		TextSize = 12,
		TextColor3 = C.chalk,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = px(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = holder,
	})
	b.Activated:Connect(function()
		if onClick then
			onClick()
		end
	end)
	self:add(holder)
	return b, holder
end

function Panel:field(labelText: string, placeholder: string, opts)
	opts = opts or {}
	self:gap(13)
	local f = Ui.frame({ Name = "Field", Size = UDim2.new(1, 0, 0, 15 + 6 + 45) })
	Ui.label({
		Text = labelText,
		TextSize = 11.5,
		TextColor3 = C.chalk,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 15),
		Parent = f,
	})
	local box = Ui.new("TextBox", {
		Text = opts.text or "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Color3.fromRGB(140, 150, 185),
		ClearTextOnFocus = false,
		TextEditable = true,
		FontFace = Ui.sans(400),
		TextSize = 15,
		TextColor3 = C.bone,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = C.black,
		BackgroundTransparency = 0.76,
		BorderSizePixel = 0,
		Position = px(0, 21),
		Size = UDim2.new(1, 0, 0, 45),
		Parent = f,
	})
	Ui.corner(box, 10)
	Ui.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = box })
	local stroke = Ui.stroke(box, C.bone, Ui.LINE_T, 1)
	box.Focused:Connect(function()
		stroke.Transparency = 0
	end)
	box.FocusLost:Connect(function()
		stroke.Transparency = Ui.LINE_T
	end)
	local busy = false
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if busy then
			return
		end
		local t = box.Text
		if opts.numeric then
			t = string.gsub(t, "%D", "")
		end
		if opts.upper then
			t = string.upper(t)
		end
		if opts.maxLen and (utf8.len(t) or #t) > opts.maxLen then
			local cut = utf8.offset(t, opts.maxLen + 1)
			t = string.sub(t, 1, (cut or (#t + 1)) - 1)
		end
		if t ~= box.Text then
			busy = true
			box.Text = t
			box.CursorPosition = #t + 1
			busy = false
		end
	end)
	self:add(f)
	return box, stroke
end

function Panel:err()
	self:gap(8)
	return self:text("", { size = 12.5, color = C.bad, minH = 15 })
end

function Panel:roster()
	self:gap(15)
	local sf = Ui.new("ScrollingFrame", {
		Name = "Roster",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.chalk,
		CanvasSize = px(0, 0),
		Size = UDim2.new(1, 0, 0, 36),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	})
	self:add(sf)
	local g = self:gap(15)
	return sf, g
end

local ROW_H = 36

local function renderRoster(sf: ScrollingFrame, players, meId: number)
	for _, c in sf:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local rows = {}
	if #players == 0 then
		table.insert(rows, { name = "waiting for players…", score = nil })
	else
		for _, p in players do
			table.insert(rows, { name = p.name or "player", score = p.score or 0, me = p.id == meId })
		end
	end
	local w = sf.AbsoluteSize.X
	for i, r in rows do
		local row = Ui.frame({ Position = px(0, (i - 1) * ROW_H), Size = UDim2.new(1, 0, 0, ROW_H), Parent = sf })
		Ui.label({
			Text = r.name,
			TextSize = 13.5,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = px(4, 0),
			Size = UDim2.new(1, -60, 1, -1),
			Parent = row,
		})
		if r.score then
			Ui.label({
				Text = tostring(r.score),
				FontFace = Ui.serif(700),
				TextSize = 17,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.new(1, -54, 0, 0),
				Size = UDim2.new(0, 50, 1, -1),
				Parent = row,
			})
		end
		Ui.frame({
			BackgroundTransparency = Ui.LINE_T,
			BackgroundColor3 = C.bone,
			Position = UDim2.new(0, 0, 1, -1),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = row,
		})
	end
	local total = #rows * ROW_H
	sf.CanvasSize = px(0, total)
	sf.Size = UDim2.new(1, 0, 0, math.min(168, total))
	local _ = w
end
Menus.renderRoster = renderRoster

---------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------
function Menus.init(bgGui: ScreenGui, gui: ScreenGui)
	M.gui = gui
	M.bg = Ui.frame({
		Name = "OverlayBg",
		BackgroundTransparency = 0,
		BackgroundColor3 = C.menuBg,
		Size = UDim2.fromScale(1, 1),
		Active = true,
		Parent = bgGui,
	})
	M.scroller = Ui.new("ScrollingFrame", {
		Name = "Overlay",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = px(0, 0),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.chalk,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Active = true,
		Parent = gui,
	})
	M.wrap = Ui.frame({ Name = "Wrap", Size = UDim2.fromScale(1, 1), Parent = M.scroller })

	-- main menu ---------------------------------------------------------------
	do
		local p = newPanel("menu", true)
		M.huge = Ui.bigText({ Name = "Huge", FontFace = Ui.serif(700), Text = "24", TextSize = 150 })
		p:add(M.huge.holder)
		local body = Ui.frame({ Name = "MenuBody", Size = px(380, 0), AutomaticSize = AUTO_Y })
		Ui.new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Parent = body,
		})
		Ui.new("UIPadding", {
			PaddingTop = UDim.new(0, 22),
			PaddingLeft = UDim.new(0, 22),
			PaddingRight = UDim.new(0, 22),
			PaddingBottom = UDim.new(0, 2),
			Parent = body,
		})
		p:add(body)
		M.menuBody = body
		p:gap(6, body)
		p:text("Four cards. Four operations. One number.", { size = 13.5, color = C.chalk }, body)
		p:gap(24, body)
		local function menuBtn(label, ghost, fn, first)
			if not first then
				p:gap(9, body)
			end
			local b = Ui.button({
				style = if ghost then "ghost" else "go",
				Text = label,
				FontFace = Ui.sans(600),
				TextSize = 13.5,
				radius = 12,
				onClick = fn,
			})
			b.inst.Size = UDim2.new(1, 0, 0, 47)
			p:add(b.inst, body)
			return b
		end
		menuBtn("Play solo", false, function()
			hook("soloBtn")
		end, false)
		menuBtn("Create a lobby", true, function()
			Menus.show("create")
		end)
		menuBtn("Join a lobby", true, function()
			Menus.show("join")
		end)
	end

	-- how it works --------------------------------------------------------------
	do
		local p = newPanel("brief")
		p:h1("How it works")
		local bone = '<font color="#f6f3ea">'
		local rk = function(s)
			return '<font face="Merriweather" color="#f6f3ea">' .. s .. "</font>"
		end
		p:rules(
			"Tap a card to send it to the equation, then an operator, then the next card.\n"
				.. "Drag a box around two or more cards on the bar to wrap them in parentheses.\n"
				.. "Tap a card on the bar to pull it back, or tap a parenthesis to ungroup.\n"
				.. rk("A")
				.. "=1 · "
				.. rk("J")
				.. "=11 · "
				.. rk("Q")
				.. "=12 · "
				.. rk("K")
				.. "=13\n"
				.. "Every hand dealt here has at least one solution."
		)
		local _ = bone
		p:para("No clock in solo. Skip as often as you like.")
		p:go("Deal me in", false, function()
			hook("briefStart")
		end, 0)
		p:tiny("← back", function()
			Menus.show("menu")
		end)
	end

	-- create ----------------------------------------------------------------------
	do
		local p = newPanel("create")
		p:h1("Pick a name")
		M.createName = p:field("Display name", "e.g. River", { maxLen = 16 })
		M.createErr = p:err()
		M.createSubmit = p:go("Create lobby", false, function()
			hook("createSubmit", M.createName.Text)
		end)
		p:tiny("← back", function()
			Menus.show("menu")
		end)
	end

	-- join ----------------------------------------------------------------------
	do
		local p = newPanel("join")
		p:h1("Enter the code")
		M.joinCode = p:field("Lobby code", "e.g. 7K3QM", { maxLen = 6, upper = true })
		M.joinName = p:field("Display name", "e.g. River", { maxLen = 16 })
		M.joinErr = p:err()
		M.joinSubmit = p:go("Join lobby", false, function()
			hook("joinSubmit", M.joinCode.Text, M.joinName.Text)
		end)
		p:tiny("← back", function()
			Menus.show("menu")
		end)
	end

	-- lobby -------------------------------------------------------------------------
	do
		local p = newPanel("lobby")
		p:kicker("Lobby code")
		M.lobbyCode = p:text("-----", { size = 42, color = C.bone, font = Ui.serif(700), rich = true })
		p:gap(8)
		M.copyCode = p:go("Copy code", true, function()
			Menus.copyCode()
		end, 0)
		-- the link row: a selectable code plus a Roblox friend invite
		p:gap(10)
		local row = Ui.frame({ Name = "LinkRow", Size = UDim2.new(1, 0, 0, 36) })
		M.linkBox = Ui.new("TextBox", {
			Text = "",
			ClearTextOnFocus = false,
			TextEditable = false,
			FontFace = Ui.sans(400),
			TextSize = 11,
			TextColor3 = C.chalk,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundColor3 = C.black,
			BackgroundTransparency = 0.76,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -78, 1, 0),
			Parent = row,
		})
		Ui.corner(M.linkBox, 10)
		Ui.stroke(M.linkBox, C.bone, Ui.LINE_T, 1)
		Ui.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = M.linkBox })
		M.inviteBtn = Ui.button({
			style = "ghost",
			Text = "Invite",
			FontFace = Ui.sans(400),
			TextSize = 11.5,
			radius = 10,
			onClick = function()
				hook("invite")
			end,
			Parent = row,
		})
		M.inviteBtn.inst.Position = UDim2.new(1, -70, 0, 0)
		M.inviteBtn.inst.Size = UDim2.new(0, 70, 1, 0)
		p:add(row)
		p:rules(
			'Everyone gets the <font color="#f6f3ea"><b>same hand at the same moment</b></font>.\n'
				.. '<font color="#f6f3ea"><b>First correct answer</b></font> takes the round — everyone else is told instantly and the next hand is dealt.\n'
				.. '<font color="#f6f3ea"><b>Win by 2.</b></font> If a hand stalls for 30 seconds, anyone can call a vote to skip it.'
		)
		M.targetInput = p:field("Points to win (win by 2)", "5", { maxLen = 2, numeric = true, text = "5" })
		M.targetInput.FocusLost:Connect(function()
			hook("targetChanged", M.targetInput.Text)
		end)
		M.lobbyRoster = p:roster()
		M.startMatch = p:go("Start match", false, function()
			hook("startMatch")
		end, 0)
		M.lobbyWaitGap = p:gap(13)
		M.lobbyWait = p:text("Waiting for the host to start the match…", { size = 12, color = C.chalk })
		p:tiny("leave lobby", function()
			hook("lobbyLeave")
		end)
	end

	-- end of session / match -------------------------------------------------------
	do
		local p = newPanel("over")
		M.overKicker = p:kicker("Session ended")
		M.overTitle = p:text("Nice run", { size = 30, color = C.bone, font = Ui.serif(700) })
		M.overTitleGap = p:gap(10)
		-- stat row
		p:gap(16)
		M.overStats = Ui.frame({ Name = "Stats", Size = UDim2.new(1, 0, 0, 56) })
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 34),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = M.overStats,
		})
		p:add(M.overStats)
		p:gap(20)
		M.overRoster, M.overRosterGap = p:roster()
		-- round-by-round log
		M.logWrap = Ui.frame({ Name = "LogWrap", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y })
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 4), Parent = M.logWrap })
		M.logToggle = Ui.button({
			style = "logToggle",
			Text = "",
			radius = 11,
			onClick = function()
				Menus.toggleLog()
			end,
			Parent = M.logWrap,
		})
		M.logToggle.inst.Size = UDim2.new(1, 0, 0, 40)
		Ui.label({
			Text = "Round-by-round",
			FontFace = Ui.sans(600),
			TextSize = 12.5,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = px(14, 0),
			Size = UDim2.new(1, -40, 1, 0),
			Parent = M.logToggle.inst,
		})
		M.logChev = Ui.chevron(C.bone)
		M.logChev.AnchorPoint = Vector2.new(0.5, 0.5)
		M.logChev.Position = UDim2.new(1, -18, 0.5, 0)
		M.logChev.Size = px(9, 9)
		M.logChev.Parent = M.logToggle.inst
		M.logList = Ui.new("ScrollingFrame", {
			Name = "LogList",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = C.chalk,
			CanvasSize = px(0, 0),
			Position = px(0, 48),
			Size = UDim2.new(1, 0, 0, 0),
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Visible = false,
			Parent = M.logWrap,
		})
		M.logSizer = Ui.frame({ Name = "Sizer", Size = UDim2.new(1, 0, 0, 40), Parent = M.logWrap })
		p:add(M.logWrap)
		M.againBtn = p:go("Play again", false, function()
			hook("againBtn")
		end)
		M.overWaitGap = p:gap(13)
		M.overWait = p:text("Waiting for the host to start a new match…", { size = 12, color = C.chalk })
		M.menuBtn = p:go("Back to menu", true, function()
			hook("menuBtn")
		end)
		M.overLeave, M.overLeaveHolder = p:tiny("leave lobby", function()
			hook("overLeave")
		end)
	end

	-- host left -----------------------------------------------------------------------
	do
		local p = newPanel("hostLeft")
		p:kicker("Lobby closed")
		p:h1("The host left")
		p:para("This lobby is no longer active. Head back to start or join another one.")
		p:go("Back to menu", false, function()
			hook("hostLeftMenuBtn")
		end, 0)
	end

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Menus.layout()
	end)
	M.scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Menus.layout()
	end)
	Menus.show("menu")
end

---------------------------------------------------------------------------
-- layout / visibility
---------------------------------------------------------------------------
function Menus.layout()
	local size = M.scroller.AbsoluteSize
	local W, H = size.X, size.Y
	if W < 10 then
		return
	end
	local panelW = math.min(0.9 * W, 420)
	for name, p in panels do
		if p.wide then
			p.inst.Size = px(W, 0)
		else
			p.inst.Size = px(panelW, 0)
		end
		local _ = name
	end
	-- menu: the huge "24"
	local fs = math.clamp(0.3 * W, 96, 190)
	M.huge.setSize(fs)
	M.huge.holder.Size = UDim2.new(1, 0, 0, fs * 0.86)
	M.menuBody.Size = px(math.min(0.9 * W, 380), 0)
	M.logList.Size = UDim2.new(1, 0, 0, M.logListH or 0)
	-- centre the active panel, scroll if it's taller than the screen
	local p = Menus.current and panels[Menus.current]
	if p then
		local h = p.inst.AbsoluteSize.Y
		local wrapH = math.max(H, h + 52)
		M.wrap.Size = UDim2.new(1, 0, 0, wrapH)
		M.scroller.CanvasSize = px(0, wrapH)
		p.inst.Position = UDim2.new(0.5, 0, 0, math.floor((wrapH - h) / 2))
	end
end

function Menus.show(name: string)
	for n, p in panels do
		p.inst.Visible = n == name
		p.inst.GroupTransparency = 0
	end
	Menus.current = name
	M.gui.Enabled = true
	M.bg.Visible = true
	M.bg.BackgroundTransparency = 0
	M.scroller.CanvasPosition = Vector2.new(0, 0)
	Menus.layout()
	task.defer(Menus.layout)
end

function Menus.isVisible(): boolean
	return M.gui ~= nil and M.gui.Enabled
end

-- Phase 1: the active panel fades out, then the solid menu background
-- fades to the table's own blue.
function Menus.fadeOut()
	local p = Menus.current and panels[Menus.current]
	if p then
		Anim.run(0.32, Anim.CSS_EASE, function(e)
			p.inst.GroupTransparency = e
		end)
		task.wait(0.32)
	end
	Anim.run(0.46, Anim.CSS_EASE, function(e)
		M.bg.BackgroundTransparency = e
	end)
	task.wait(0.46)
	M.gui.Enabled = false
	M.bg.Visible = false
	M.bg.BackgroundTransparency = 0
	if p then
		p.inst.GroupTransparency = 0
	end
	Menus.current = nil
end

---------------------------------------------------------------------------
-- lobby screen helpers
---------------------------------------------------------------------------
function Menus.setLobby(code: string, isHost: boolean, inviteHint: string)
	M.lobbyCode.Text = Ui.spaced(code, 20)
	M.lobbyCode.TextSize = 42
	M.linkBox.Text = inviteHint
	M.startMatch.inst.Visible = isHost
	M.lobbyWait.Visible = not isHost
	M.lobbyWaitGap.Visible = not isHost
	M.targetInput.TextEditable = isHost
	M.targetInput.TextColor3 = if isHost then C.bone else C.chalk
end

function Menus.setTarget(v: number)
	if UserInputService:GetFocusedTextBox() == M.targetInput then
		return
	end
	M.targetInput.Text = tostring(v)
end

function Menus.getTargetText(): string
	return M.targetInput.Text
end

function Menus.renderLobbyRoster(players, meId: number)
	renderRoster(M.lobbyRoster, players, meId)
end

function Menus.setStartBusy(busy: boolean)
	M.startMatch.setText(if busy then "Shuffling…" else "Start match")
	M.startMatch.setDisabled(busy)
end

local copyToken = 0
function Menus.copyCode()
	-- Roblox can't write the clipboard; select the code so Ctrl+C copies it
	copyToken += 1
	local token = copyToken
	local box = M.linkBox
	local code = box:GetAttribute("Code") or ""
	if UserInputService.KeyboardEnabled then
		box.Text = code
		box:CaptureFocus()
		box.SelectionStart = 1
		box.CursorPosition = #code + 1
		M.copyCode.setText("Press Ctrl+C to copy")
	else
		M.copyCode.setText("Code: " .. code)
	end
	task.delay(2.2, function()
		if token == copyToken then
			M.copyCode.setText("Copy code")
		end
	end)
end

function Menus.setLinkCode(code: string)
	M.linkBox:SetAttribute("Code", code)
end

function Menus.setInviteText(t: string)
	M.inviteBtn.setText(t)
end

function Menus.fields()
	return M
end

---------------------------------------------------------------------------
-- end screen
---------------------------------------------------------------------------
local function statCell(big: string, small: string, order: number)
	local f = Ui.frame({ Size = px(0, 56), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Parent = M.overStats })
	local bw = Ui.textWidth(big, 30, "serif", 700) + 4
	local sw = Ui.textWidth(small, 11, "sans") + 4
	local w = math.max(bw, sw)
	f.AutomaticSize = Enum.AutomaticSize.None
	f.Size = px(w, 56)
	Ui.label({
		Text = big,
		FontFace = Ui.serif(700),
		TextSize = 30,
		Size = px(w, 38),
		Parent = f,
	})
	Ui.label({
		Text = small,
		TextSize = 11,
		TextColor3 = C.chalk,
		Position = px(0, 40),
		Size = px(w, 15),
		Parent = f,
	})
end

function Menus.setOver(o)
	M.overKicker.Text = o.kicker
	M.overTitle.Text = o.title
	if o.verdict then
		M.overTitle.TextSize = math.clamp(0.14 * M.scroller.AbsoluteSize.X, 46, 92)
		M.overTitleGap.Size = UDim2.new(1, 0, 0, 8)
	else
		M.overTitle.TextSize = 30
		M.overTitleGap.Size = UDim2.new(1, 0, 0, 10)
	end
	for _, c in M.overStats:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, s in o.stats do
		statCell(s[1], s[2], i)
	end
	M.overRoster.Visible = o.roster ~= nil
	M.overRosterGap.Visible = o.roster ~= nil
	if o.roster then
		renderRoster(M.overRoster, o.roster, o.meId)
	end
	M.againBtn.inst.Visible = o.again ~= nil
	if o.again then
		M.againBtn.setText(o.again)
	end
	M.overWait.Visible = o.wait == true
	M.overWaitGap.Visible = o.wait == true
	M.menuBtn.inst.Visible = o.menu == true
	M.overLeaveHolder.Visible = o.leave == true
	Menus.renderLog(o.history or {}, o.showLog == true)
end

-- round-by-round log -----------------------------------------------------
local logItems = {}

local function logWidth(): number
	return math.max(100, M.logWrap.AbsoluteSize.X - 2)
end

local function relayoutLog()
	local y = 0
	for i, it in logItems do
		it.frame.Position = px(0, y)
		y += it.h + (if i < #logItems then 7 else 0)
	end
	M.logList.CanvasSize = px(0, y)
	local open = M.logList.Visible
	local maxH = math.min(0.46 * M.scroller.AbsoluteSize.Y, 340)
	M.logListH = if open then math.min(maxH, y) else 0
	M.logList.Size = UDim2.new(1, 0, 0, M.logListH)
	M.logSizer.Size = UDim2.new(1, 0, 0, 40 + (if open then 8 + M.logListH else 0))
	Menus.layout()
end

local function buildLogItem(h)
	local cards = h.p or {}
	local item = { frame = Ui.frame({ Name = "LogItem", Parent = M.logList }), h = 0 }
	local mcw, mch = Play.miniSize()

	local collapsed, expanded

	local function clear()
		for _, c in item.frame:GetChildren() do
			c:Destroy()
		end
	end

	collapsed = function()
		clear()
		local w = logWidth()
		local head = Ui.button({
			style = "logHead",
			Text = "",
			radius = 11,
			onClick = function()
				expanded()
			end,
			Parent = item.frame,
		})
		local metaRich = if h.skipped
			then "skipped by vote"
			else '<font color="#f6f3ea"><b>'
				.. Ui.escape(h.wn or "player")
				.. "</b></font> · "
				.. string.format("%.2f", (h.ms or 0) / 1000)
				.. "s"
		local metaPlain = if h.skipped
			then "skipped by vote"
			else (h.wn or "player") .. " · " .. string.format("%.2f", (h.ms or 0) / 1000) .. "s"
		local metaW = Ui.textWidth(metaPlain, 11, "sans", 500) + 4
		local rLabel = "Hand " .. tostring(h.r)
		local rW = math.max(50, Ui.textWidth(rLabel, 10.5, "sans") + 2)
		local inner = w - 22
		local cardsW = 4 * mcw + 3 * 9
		local oneLine = rW + 9 + cardsW + 9 + metaW <= inner
		local lineH = mch
		local hh = if oneLine then lineH + 18 else lineH + 9 + 14 + 18
		head.inst.Size = px(w, hh)
		Ui.label({
			Text = rLabel,
			TextSize = 10.5,
			TextColor3 = C.chalk,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = px(11, 9),
			Size = px(rW, lineH),
			Parent = head.inst,
		})
		local x = 11 + rW + 9
		for i, c in cards do
			local mc = Play.miniCard(c, head.inst)
			mc.Position = px(x + (i - 1) * (mcw + 9), 9)
		end
		Ui.label({
			Text = metaRich,
			RichText = true,
			TextSize = 11,
			TextColor3 = C.chalk,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = if oneLine then px(w - 11 - metaW, 9) else px(w - 11 - metaW, 9 + lineH + 9),
			Size = px(metaW, if oneLine then lineH else 14),
			Parent = head.inst,
		})
		item.h = hh
		item.frame.Size = px(w, hh)
	end

	expanded = function()
		clear()
		local w = logWidth()
		local d = Ui.frame({
			BackgroundTransparency = 0.7,
			BackgroundColor3 = C.black,
			Size = px(w, 0),
			Parent = item.frame,
		})
		Ui.corner(d, 11)
		Ui.stroke(d, C.white, 0.76, 1)
		local inner = w - 24
		local y = 11

		-- title + close
		local sub = if h.skipped
			then "nobody solved it — skipped by vote"
			else "won by " .. (h.wn or "player") .. " in " .. string.format("%.2f", (h.ms or 0) / 1000) .. " seconds"
		local subLines = math.max(1, math.ceil(Ui.textWidth(sub, 10.5, "sans") / (inner - 36)))
		Ui.label({
			Text = "Hand " .. tostring(h.r),
			FontFace = Ui.sans(600),
			TextSize = 12.5,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = px(12, y),
			Size = px(inner - 36, 16),
			Parent = d,
		})
		Ui.label({
			Text = sub,
			TextSize = 10.5,
			TextColor3 = C.chalk,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = px(12, y + 19),
			Size = px(inner - 36, subLines * 13.7),
			Parent = d,
		})
		local close = Ui.button({
			style = "close",
			Text = "",
			radius = UDim.new(0.5, 0),
			onClick = function()
				collapsed()
				relayoutLog()
			end,
			Parent = d,
		})
		close.inst.Position = px(w - 12 - 26, y)
		close.inst.Size = px(26, 26)
		local x, setX = Ui.cross(C.bone, 1.4)
		x.AnchorPoint = Vector2.new(0.5, 0.5)
		x.Position = UDim2.fromScale(0.5, 0.5)
		x.Size = px(9, 9)
		x.Parent = close.inst
		local _ = setX
		y += math.max(26, 19 + subLines * 13.7) + 8

		local function sectionLabel(t, upper)
			Ui.label({
				Text = if upper == false then t else string.upper(t),
				TextSize = 10,
				TextColor3 = C.chalk,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = px(12, y + 2),
				Size = px(inner, 13),
				Parent = d,
			})
			y += 15 + 8
		end
		local function addRow(row, rh)
			row.Position = px(12, y)
			row.Parent = d
			y += rh + 8
		end

		-- the hand
		sectionLabel("the hand")
		local handToks = {}
		for i = 1, #cards do
			table.insert(handToks, { type = "card", cardIdx = i })
		end
		addRow(Play.miniRow(handToks, cards, nil, inner))

		-- the winning equation
		local winnerCanon = nil
		if not h.skipped and h.eq and h.eq ~= "" then
			local wToks = Solver.parseEqString(h.eq)
			sectionLabel("winning equation")
			addRow(Play.miniRow(wToks, cards, nil, inner))
			local wTree = Solver.tokensToTree(wToks, cards)
			if wTree then
				winnerCanon = Solver.canonTree(wTree)
			end
		end

		-- every other distinct solution
		local all = if #cards == 4 then Solver.uniqueSolutions(cards) else {}
		local others = {}
		for _, t in all do
			if not winnerCanon or Solver.canonTree(t) ~= winnerCanon then
				table.insert(others, t)
			end
		end
		sectionLabel((if winnerCanon then "other solutions" else "all solutions") .. " (" .. #others .. ")")
		if #others > 0 then
			local scroll = Ui.new("ScrollingFrame", {
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 3,
				ScrollBarImageColor3 = C.chalk,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				Position = px(12, y),
				Parent = d,
			})
			local sy = 0
			for i, t in others do
				local row, rh = Play.miniRow(Solver.treeToTokens(t), cards, "#" .. i, inner - 6)
				row.BackgroundTransparency = 0.91
				row.Position = px(0, sy)
				row.Parent = scroll
				sy += rh + 6
			end
			sy -= 6
			local sh = math.min(186, sy)
			scroll.Size = px(inner, sh)
			scroll.CanvasSize = px(0, sy)
			y += sh + 8
		else
			y -= 8
			sectionLabel("that was the only way to make 24", false)
		end
		y = y - 8 + 13
		d.Size = px(w, y)
		item.h = y
		item.frame.Size = px(w, y)
		relayoutLog()
	end

	collapsed()
	return item
end

function Menus.renderLog(history, show: boolean)
	for _, it in logItems do
		it.frame:Destroy()
	end
	logItems = {}
	M.logList.Visible = false
	M.logList.CanvasPosition = Vector2.new(0, 0)
	M.logChev.Rotation = 0
	M.logWrap.Visible = show and #history > 0
	if not M.logWrap.Visible then
		return
	end
	-- widths are only known once the panel is laid out
	task.defer(function()
		for _, h in history do
			table.insert(logItems, buildLogItem(h))
		end
		relayoutLog()
	end)
end

function Menus.toggleLog()
	local open = not M.logList.Visible
	M.logList.Visible = open
	Ui.tween(M.logChev, 0.16, { Rotation = if open then 90 else 0 })
	relayoutLog()
end

return Menus

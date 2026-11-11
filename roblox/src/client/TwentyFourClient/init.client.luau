--[[
	TwentyFourClient — boots the table and runs the flow: solo sessions,
	lobbies and the multiplayer race (sections 5–8 of the web version).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local SocialService = game:GetService("SocialService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("TwentyFour")
local Config = require(Shared:WaitForChild("Config"))
local Solver = require(Shared:WaitForChild("Solver"))
local Request = Shared:WaitForChild("Request")
local LobbyState = Shared:WaitForChild("LobbyState")

local Modules = script:WaitForChild("Modules")
local Ui = require(Modules:WaitForChild("Ui"))
local Play = require(Modules:WaitForChild("Play"))
local Menus = require(Modules:WaitForChild("Menus"))

local ME = player.UserId

---------------------------------------------------------------------------
-- environment: a full-screen 2D table, no avatar chrome
---------------------------------------------------------------------------
local function coreOff()
	local types = {
		Enum.CoreGuiType.PlayerList,
		Enum.CoreGuiType.Backpack,
		Enum.CoreGuiType.Health,
		Enum.CoreGuiType.EmotesMenu,
	}
	if not Config.ENABLE_CHAT then
		table.insert(types, Enum.CoreGuiType.Chat)
	end
	for _, t in types do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(t, false)
		end)
	end
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", false)
	end)
end
task.spawn(function()
	for _ = 1, 10 do
		coreOff()
		task.wait(1)
	end
end)
if not Config.ENABLE_CHAT then
	pcall(function()
		local win = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if win then
			win.Enabled = false
		end
		local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if bar then
			bar.Enabled = false
		end
	end)
end
pcall(function()
	GuiService.TouchControlsEnabled = false
end)
pcall(function()
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.new(0, 10000, 0)
end)

local function screenGui(name: string, order: number, ignoreInset: boolean)
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = ignoreInset
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = order
	g.Parent = playerGui
	return g
end

local bgGui = screenGui("TwentyFour_Bg", 0, true)
Ui.frame({
	Name = "Royal",
	BackgroundTransparency = 0,
	BackgroundColor3 = Ui.C.royal,
	Size = UDim2.fromScale(1, 1),
	Parent = bgGui,
})
local playGui = screenGui("TwentyFour_Table", 1, false)
local overlayBgGui = screenGui("TwentyFour_OverlayBg", 5, true)
local menuGui = screenGui("TwentyFour_Menus", 6, false)
local selGui = screenGui("TwentyFour_Selection", 20, false)

Play.init(playGui, selGui)
Menus.init(overlayBgGui, menuGui)
Play.hooks.isOverlayVisible = Menus.isVisible

---------------------------------------------------------------------------
-- server requests
---------------------------------------------------------------------------
local function req(action: string, ...)
	local args = table.pack(...)
	local ok, res = pcall(function()
		return Request:InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if ok and typeof(res) == "table" then
		return res
	end
	return { ok = false, err = "Couldn't reach the server. Try again." }
end

local function now(): number
	return workspace:GetServerTimeNow()
end

---------------------------------------------------------------------------
-- flow state
---------------------------------------------------------------------------
local F = {
	lobbyCode = nil,
	isHost = false,
	lastMatchId = 0,
	lobbyWatch = false, -- the web version's lobby polling: on in lobby / results
	latest = nil, -- newest lobby snapshot
	mode = nil,
	busy = false,
}
local mp = { live = false, over = true, gen = 0 }

local function setMode(m)
	F.mode = m
	Play.setMode(m)
end

---------------------------------------------------------------------------
-- solo (section 6)
---------------------------------------------------------------------------
local function leaveLobbyState()
	F.lobbyCode = nil
	F.isHost = false
	F.lastMatchId = 0
	F.lobbyWatch = false
	F.latest = nil
	mp.live = false
	mp.over = true
	mp.gen += 1
	Play.clearModeChrome()
end

local function startSolo()
	if F.busy then
		return
	end
	F.busy = true
	if F.lobbyCode then
		task.spawn(req, "leaveLobby")
	end
	leaveLobbyState()
	setMode("solo")
	Play.setSolved(0)
	Play.applySoloChrome()
	task.spawn(req, "soloStart")
	Play.dealNew(nil, { deal = false, locked = true })
	Play.syncControls()
	Menus.fadeOut()
	Play.revealHud()
	task.wait(0.28)
	Play.revealRest()
	-- deal only once the table is actually on screen
	Play.dealNew(nil, { locked = true })
	task.wait(Play.dealDuration())
	F.busy = false
	if F.mode == "solo" then
		Play.setLocked(false)
	end
end

local function endSolo()
	local solved, best = Play.S.solved, Play.S.best
	Play.leavePlay()
	setMode(nil)
	Menus.setOver({
		kicker = "Session ended",
		title = if solved == 0 then "Next time" elseif solved == 1 then "One down" else solved .. " solved",
		stats = { { tostring(solved), "solved" }, { tostring(best), "best" } },
		again = "Play again",
		menu = true,
	})
	Menus.show("over")
end

Play.hooks.onSoloSolved = function()
	task.spawn(function()
		local res = req("soloSolved")
		if res.ok and typeof(res.best) == "number" and res.best > Play.S.best then
			Play.setBest(res.best)
		end
	end)
end

---------------------------------------------------------------------------
-- multiplayer (section 7)
---------------------------------------------------------------------------
local function majorityNeeded(n: number): number
	if n <= 2 then
		return n
	end
	return math.floor(n / 2) + 1
end

local function renderVoteUI(snap)
	local m = snap and snap.match
	if F.mode ~= "mp" or mp.over or not m or (m.voteSession or 0) == 0 or now() < (m.voteOpenAt or 0) then
		Play.hideVote()
		return
	end
	local here = {}
	for _, p in snap.players do
		if not p.stale then
			table.insert(here, p)
		end
	end
	if #here == 0 then
		here = snap.players
	end
	local names = {}
	local iVoted = false
	for _, p in here do
		local voted = p.voted or (p.id == ME and mp.votedSession == m.voteSession)
		if voted then
			table.insert(names, if p.id == ME then "you" else (p.name or "player"))
			if p.id == ME then
				iVoted = true
			end
		end
	end
	local need = majorityNeeded(#here)
	Play.showVote("Skip this hand? " .. #names .. " of " .. need .. " needed", names, iVoted)
end

local function scheduleUnlock()
	local gen = mp.gen
	local round = mp.round
	task.delay(math.max(0, mp.roundStartAt - now()), function()
		if gen ~= mp.gen or mp.over or mp.round ~= round then
			return
		end
		Play.S.locked = false
		Play.clearSay()
		Play.syncControls()
	end)
end

local function onNewRound(snap)
	local m = snap.match
	mp.round = m.round
	mp.roundStartAt = m.roundStartAt or now()
	mp.claimed = false
	Play.S.locked = true
	Play.hideVote()

	-- announce how the previous hand ended
	local res = m.lastResult
	if res and res.r == m.round - 1 then
		if res.skipped then
			Play.say("hand skipped by vote", "note")
		elseif res.wid == ME then
			Play.say("you took it in " .. string.format("%.2f", res.ms / 1000) .. "s", "good")
		else
			Play.say((res.wn ~= "" and res.wn or "someone") .. " took it in " .. string.format("%.2f", res.ms / 1000) .. "s", "note")
		end
	end
	Play.replaceHand(m.puzzle, { locked = true, keepSay = true })
	Play.syncControls()
	scheduleUnlock()
end

local showMpResults

local function onMatchFinished(snap)
	if mp.over then
		return
	end
	mp.over = true
	mp.live = false
	mp.gen += 1
	Play.S.locked = true
	Play.syncControls()
	showMpResults(snap)
end

local function processMatchSnap(snap)
	local m = snap.match
	if not m or m.id ~= mp.matchId then
		return
	end
	if snap.status == "finished" then
		onMatchFinished(snap)
		return
	end
	if snap.status ~= "active" then
		return
	end
	if m.round ~= mp.round then
		onNewRound(snap)
	end
	Play.renderBoard(snap.players, ME)
	renderVoteUI(snap)
end

local function enterMatch(snap)
	local m = snap.match
	setMode("mp")
	mp = {
		live = false,
		over = false,
		gen = mp.gen + 1,
		matchId = m.id,
		target = m.target or Config.MP_DEFAULT_TARGET,
		round = m.round,
		roundStartAt = m.roundStartAt or now(),
		claimed = false,
	}
	local gen = mp.gen
	F.lobbyWatch = false
	Play.setSolved(0)
	Play.applyMpChrome(mp.target)
	Play.hideVote()
	Play.renderBoard(snap.players, ME)
	Play.dealNew(m.puzzle, { deal = false, locked = true })
	Play.syncControls()

	-- Phase 1: the menu fades away completely
	Menus.fadeOut()
	if gen ~= mp.gen then
		return
	end
	-- Phase 2: ready / set / go plays in full for everyone
	Play.runCurtain(Config.MP_CURTAIN)
	if gen ~= mp.gen then
		return
	end
	-- Phase 3: the same staged reveal as solo
	Play.revealHud()
	task.wait(0.28)
	Play.animateDeal()
	Play.revealRest()
	task.wait(Play.dealDuration())
	if gen ~= mp.gen then
		return
	end
	mp.live = true
	scheduleUnlock()
	if F.latest then
		processMatchSnap(F.latest)
	end
end

showMpResults = function(snap)
	Play.leavePlay()
	setMode(nil)
	local m = snap.match or {}
	local iWon = m.winnerId == ME
	local myScore, topScore = 0, 0
	for i, p in snap.players do
		if p.id == ME then
			myScore = p.score or 0
		end
		if i == 1 then
			topScore = p.score or 0
		end
	end
	Menus.setOver({
		kicker = if iWon then "Match won" else "Match over",
		title = if iWon then "W" else "L",
		verdict = true,
		stats = { { tostring(myScore), "your score" }, { tostring(topScore), "winning score" } },
		roster = snap.players,
		meId = ME,
		history = m.history or {},
		showLog = true,
		again = if F.isHost then "New match" else nil,
		wait = not F.isHost,
		leave = true,
	})
	Menus.show("over")
	F.lobbyWatch = true
end

Play.hooks.onMpClaim = function(toks)
	if mp.claimed or mp.over then
		return
	end
	mp.claimed = true
	local round = mp.round
	local ms = math.max(0, (now() - mp.roundStartAt) * 1000)
	Play.S.locked = true
	Play.syncControls()
	Play.say("24 in " .. string.format("%.2f", ms / 1000) .. "s \u{2014} checking\u{2026}", "good")
	task.spawn(function()
		local res = req("claim", round, ms, Solver.eqTokensToString(toks))
		if not res.ok and mp.round == round and not mp.over then
			-- the claim didn't land (the hand may have moved on)
			mp.claimed = false
			Play.S.locked = false
			Play.syncControls()
			Play.sayTemp("that answer didn't reach the table \u{2014} try again", "note", 1.6)
		end
	end)
end

Play.hooks.onVote = function()
	local snap = F.latest
	local m = snap and snap.match
	if F.mode ~= "mp" or mp.over or not m or (m.voteSession or 0) == 0 then
		return
	end
	mp.votedSession = m.voteSession
	renderVoteUI(snap)
	task.spawn(req, "vote", m.voteSession)
end

---------------------------------------------------------------------------
-- lobby snapshots (replaces the web version's polling loops)
---------------------------------------------------------------------------
local function onSnapshot(snap)
	if typeof(snap) ~= "table" then
		return
	end
	if snap.closed then
		if snap.code == F.lobbyCode and not F.isHost then
			if F.mode == "mp" then
				Play.leavePlay()
				setMode(nil)
			end
			leaveLobbyState()
			Menus.show("hostLeft")
		end
		return
	end
	if snap.code ~= F.lobbyCode then
		return
	end
	F.latest = snap
	F.isHost = snap.hostId == ME

	if Menus.current == "lobby" then
		Menus.renderLobbyRoster(snap.players, ME)
		if not F.isHost and snap.target then
			Menus.setTarget(snap.target)
		end
	end

	if F.lobbyWatch and snap.status == "active" and snap.match and snap.match.id ~= F.lastMatchId then
		F.lastMatchId = snap.match.id
		task.spawn(enterMatch, snap)
		return
	end

	if F.mode == "mp" and mp.live then
		processMatchSnap(snap)
	end
end
LobbyState.OnClientEvent:Connect(onSnapshot)

-- votes open on a timer, so keep the vote bar honest between snapshots
task.spawn(function()
	while true do
		task.wait(0.5)
		if F.mode == "mp" and mp.live and not mp.over then
			renderVoteUI(F.latest)
		end
	end
end)

local function enterLobbyScreen(snap)
	F.latest = snap
	F.isHost = snap.hostId == ME
	F.lastMatchId = if snap.match then snap.match.id else 0
	Menus.setLobby(F.lobbyCode, F.isHost, "Share the code: " .. F.lobbyCode)
	Menus.setLinkCode(F.lobbyCode)
	Menus.setTarget(snap.target or Config.MP_DEFAULT_TARGET)
	Menus.setStartBusy(false)
	Menus.show("lobby")
	Menus.renderLobbyRoster(snap.players, ME)
	F.lobbyWatch = true
end

local function hostStartMatch()
	if not F.isHost or not F.lobbyCode then
		return
	end
	Menus.setStartBusy(true)
	local target = tonumber(Menus.getTargetText()) or Config.MP_DEFAULT_TARGET
	local res = req("startMatch", target)
	Menus.setStartBusy(false)
	if not res.ok then
		return
	end
end

---------------------------------------------------------------------------
-- wiring (section 8)
---------------------------------------------------------------------------
local fields = Menus.fields()

Menus.hooks.soloBtn = function()
	if F.lobbyCode then
		task.spawn(req, "leaveLobby")
	end
	leaveLobbyState()
	Menus.show("brief")
end
Menus.hooks.briefStart = startSolo

Menus.hooks.createSubmit = function(name)
	if F.busy then
		return
	end
	F.busy = true
	fields.createErr.Text = ""
	fields.createSubmit.setText("Creating…")
	local res = req("createLobby", name)
	fields.createSubmit.setText("Create lobby")
	F.busy = false
	if not res.ok then
		fields.createErr.Text = res.err or "Could not create the lobby."
		return
	end
	F.lobbyCode = res.snap.code
	enterLobbyScreen(res.snap)
end

local function joinLobby(code, name)
	if F.busy then
		return
	end
	code = string.upper((string.gsub(code or "", "%s", "")))
	fields.joinErr.Text = ""
	if code == "" then
		fields.joinErr.Text = "Enter the lobby code."
		return
	end
	F.busy = true
	fields.joinSubmit.setText("Joining…")
	local res = req("joinLobby", code, name)
	fields.joinSubmit.setText("Join lobby")
	F.busy = false
	if not res.ok then
		fields.joinErr.Text = res.err or "Could not join that lobby."
		return
	end
	F.lobbyCode = res.snap.code
	enterLobbyScreen(res.snap)
end
Menus.hooks.joinSubmit = joinLobby

Menus.hooks.invite = function()
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if not ok or not can then
		Menus.setInviteText("n/a")
		task.delay(1.6, Menus.setInviteText, "Invite")
		return
	end
	pcall(function()
		local opts = Instance.new("ExperienceInviteOptions")
		opts.PromptMessage = "Join my 24 lobby"
		opts.LaunchData = F.lobbyCode or ""
		SocialService:PromptGameInvite(player, opts)
	end)
end

Menus.hooks.targetChanged = function(text)
	if not F.isHost then
		return
	end
	local v = tonumber(text) or Config.MP_DEFAULT_TARGET
	if v < 1 then
		v = Config.MP_DEFAULT_TARGET
	end
	v = math.min(Config.MP_MAX_TARGET, math.floor(v))
	Menus.setTarget(v)
	req("setTarget", v)
end

Menus.hooks.startMatch = hostStartMatch

local function leaveToMenu()
	if F.lobbyCode then
		task.spawn(req, "leaveLobby")
	end
	leaveLobbyState()
	Menus.show("menu")
end
Menus.hooks.lobbyLeave = leaveToMenu
Menus.hooks.overLeave = leaveToMenu
Menus.hooks.menuBtn = leaveToMenu
Menus.hooks.hostLeftMenuBtn = function()
	leaveLobbyState()
	Menus.show("menu")
end

Menus.hooks.againBtn = function()
	if F.lobbyCode and F.isHost then
		hostStartMatch()
	elseif not F.lobbyCode then
		startSolo()
	end
end

Play.hooks.onQuit = function()
	if F.mode == "solo" then
		endSolo()
		return
	end
	if F.mode == "mp" then
		mp.over = true
		mp.live = false
		mp.gen += 1
		Play.leavePlay()
		setMode(nil)
		Menus.show("lobby")
		F.lobbyWatch = true
		task.spawn(function()
			local res = req("away")
			if res.ok and res.snap and F.lobbyCode then
				F.latest = res.snap
				if Menus.current == "lobby" then
					Menus.renderLobbyRoster(res.snap.players, ME)
				end
			end
		end)
		if F.latest then
			Menus.renderLobbyRoster(F.latest.players, ME)
		end
		return
	end
	leaveToMenu()
end

-- the logo goes straight home from anywhere in-game
Play.hooks.onHome = function()
	if F.mode == "solo" or F.mode == "mp" then
		Play.leavePlay()
	end
	setMode(nil)
	leaveToMenu()
end

---------------------------------------------------------------------------
-- boot
---------------------------------------------------------------------------
task.spawn(function()
	local hello = req("hello")
	if not hello.ok then
		return
	end
	if typeof(hello.best) == "number" then
		Play.setBest(hello.best)
	end
	local dn = hello.displayName or player.DisplayName
	if fields.createName.Text == "" then
		fields.createName.PlaceholderText = "e.g. " .. dn
	end
	if fields.joinName.Text == "" then
		fields.joinName.PlaceholderText = "e.g. " .. dn
	end
	-- arrived through a friend invite or a cross-server lobby hop
	local pj = hello.pendingJoin
	if typeof(pj) == "table" and typeof(pj.code) == "string" then
		fields.joinCode.Text = string.upper(pj.code)
		if typeof(pj.name) == "string" then
			fields.joinName.Text = pj.name
		end
		Menus.show("join")
		if pj.auto then
			joinLobby(pj.code, pj.name)
		end
	end
end)

-- keep the (touch) keyboard from covering things on phones
UserInputService.TextBoxFocusReleased:Connect(function()
	Menus.layout()
end)

--[[
	TwentyFourServer — lobbies, the synchronised race, solo bests.

	Replaces the web version's Firebase lobby documents. The server is the
	single arbiter: it deals the hands, stamps the shared round start, checks
	every claimed answer, ranks near-simultaneous claims by elapsed time,
	runs vote-to-skip and decides the match (first to N, win by 2).

	Clients talk to it through one RemoteFunction ("Request") and receive a
	full lobby snapshot through one RemoteEvent ("LobbyState") whenever
	anything changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")

-- a pure 2D card table: nobody needs an avatar
pcall(function()
	Players.CharacterAutoLoads = false
end)

local Shared = ReplicatedStorage:WaitForChild("TwentyFour")
local Solver = require(Shared:WaitForChild("Solver"))
local Config = require(Shared:WaitForChild("Config"))

local Request = Instance.new("RemoteFunction")
Request.Name = "Request"
Request.Parent = Shared
local LobbyState = Instance.new("RemoteEvent")
LobbyState.Name = "LobbyState"
LobbyState.Parent = Shared

local function now(): number
	return workspace:GetServerTimeNow()
end

local IS_STUDIO = RunService:IsStudio()

---------------------------------------------------------------------------
-- solo bests (DataStore)
---------------------------------------------------------------------------
local bestStore = nil
pcall(function()
	bestStore = DataStoreService:GetDataStore(Config.BEST_STORE)
end)

local profiles = {} -- [userId] = { best, loaded, dirty, soloCount, lastSolveAt }

local function loadProfile(player: Player)
	local prof = { best = 0, loaded = false, dirty = false, soloCount = 0, lastSolveAt = 0 }
	profiles[player.UserId] = prof
	if bestStore then
		local ok, val = pcall(function()
			return bestStore:GetAsync("u_" .. player.UserId)
		end)
		if ok and typeof(val) == "number" then
			prof.best = math.max(prof.best, val)
		end
	end
	prof.loaded = true
	return prof
end

local function saveProfile(userId: number)
	local prof = profiles[userId]
	if not prof or not prof.dirty or not bestStore then
		return
	end
	prof.dirty = false
	local best = prof.best
	pcall(function()
		bestStore:UpdateAsync("u_" .. userId, function(old)
			if typeof(old) == "number" and old >= best then
				return nil
			end
			return best
		end)
	end)
end

task.spawn(function()
	while true do
		task.wait(30)
		for userId in profiles do
			task.spawn(saveProfile, userId)
		end
	end
end)

---------------------------------------------------------------------------
-- lobby directory (MemoryStore) so a code works from any server
---------------------------------------------------------------------------
local directory = nil
pcall(function()
	directory = MemoryStoreService:GetHashMap(Config.LOBBY_DIRECTORY)
end)
local CROSS_SERVER = directory ~= nil and not IS_STUDIO and game.JobId ~= ""

local function dirSet(code: string)
	if not CROSS_SERVER then
		return
	end
	task.spawn(function()
		pcall(function()
			directory:SetAsync(code, { jobId = game.JobId, placeId = game.PlaceId }, 60 * 60 * 3)
		end)
	end)
end
local function dirRemove(code: string)
	if not CROSS_SERVER then
		return
	end
	task.spawn(function()
		pcall(function()
			directory:RemoveAsync(code)
		end)
	end)
end
local function dirGet(code: string)
	if not CROSS_SERVER then
		return nil
	end
	local ok, val = pcall(function()
		return directory:GetAsync(code)
	end)
	if ok and typeof(val) == "table" then
		return val
	end
	return nil
end

---------------------------------------------------------------------------
-- lobbies
---------------------------------------------------------------------------
local lobbies = {} -- [code] = lobby
local playerLobby = {} -- [userId] = code
local nextMatchId = 0

local CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
local rng = Random.new()

local function genCode(): string
	for _ = 1, 50 do
		local c = {}
		for i = 1, 5 do
			local k = rng:NextInteger(1, #CODE_CHARS)
			c[i] = string.sub(CODE_CHARS, k, k)
		end
		local code = table.concat(c)
		if not lobbies[code] and not dirGet(code) then
			return code
		end
	end
	return tostring(rng:NextInteger(10000, 99999))
end

local function filterName(player: Player, raw: any): string
	local name = if typeof(raw) == "string" then raw else ""
	name = string.gsub(name, "[%c]", "")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	if utf8.len(name) == nil then
		name = ""
	end
	-- 16 characters, like the web version's maxlength
	if (utf8.len(name) or 0) > 16 then
		name = string.sub(name, 1, (utf8.offset(name, 17) or (#name + 1)) - 1)
	end
	if name == "" then
		return player.DisplayName
	end
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(name, player.UserId)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if ok and typeof(filtered) == "string" and filtered ~= "" then
		return filtered
	end
	return player.DisplayName
end

local function orderedMembers(lobby)
	local list = {}
	for i, id in lobby.order do
		local m = lobby.members[id]
		if m then
			table.insert(list, { m = m, i = i })
		end
	end
	table.sort(list, function(a, b)
		if a.m.score ~= b.m.score then
			return a.m.score > b.m.score
		end
		return a.i < b.i
	end)
	local out = {}
	for _, e in list do
		table.insert(out, e.m)
	end
	return out
end

local function isHere(m): boolean
	return not m.left and not m.away
end

-- Players who are actually at the table. Someone who left must not hold a
-- vote hostage, but this never empties the list entirely.
local function activeMembers(lobby)
	local all = orderedMembers(lobby)
	local live = {}
	for _, m in all do
		if isHere(m) then
			table.insert(live, m)
		end
	end
	return if #live > 0 then live else all
end

local function majorityNeeded(n: number): number
	if n <= 2 then
		return n
	end
	return math.floor(n / 2) + 1
end

local function snapshot(lobby)
	local match = lobby.match
	local players = {}
	for _, m in orderedMembers(lobby) do
		table.insert(players, {
			id = m.id,
			name = m.name,
			score = m.score,
			stale = not isHere(m),
			voted = match ~= nil and match.voteSession > 0 and m.voteSession == match.voteSession,
		})
	end
	local snap = {
		code = lobby.code,
		hostId = lobby.hostId,
		status = lobby.status,
		target = lobby.target,
		players = players,
		sentAt = now(),
	}
	if match then
		snap.match = {
			id = match.id,
			target = match.target,
			round = match.round,
			roundStartAt = match.roundStartAt,
			puzzle = match.puzzles[match.round],
			voteSession = match.voteSession,
			voteOpenAt = match.voteOpenAt,
			lastResult = match.lastResult,
			winnerId = match.winnerId,
			winnerName = match.winnerName,
			-- the full log is only needed once the match is decided
			history = if lobby.status == "finished" then match.history else nil,
		}
	end
	return snap
end

local function broadcast(lobby)
	local snap = snapshot(lobby)
	for id, m in lobby.members do
		if not m.left then
			local p = Players:GetPlayerByUserId(id)
			if p then
				LobbyState:FireClient(p, snap)
			end
		end
	end
end

local function closeLobby(lobby, reason: string)
	lobby.status = "closed"
	lobbies[lobby.code] = nil
	dirRemove(lobby.code)
	for id, m in lobby.members do
		if playerLobby[id] == lobby.code then
			playerLobby[id] = nil
		end
		if not m.left and id ~= lobby.hostId then
			local p = Players:GetPlayerByUserId(id)
			if p then
				LobbyState:FireClient(p, { code = lobby.code, closed = reason })
			end
		end
	end
end

local function resetMemberRound(m)
	m.solvedRound = -1
	m.solvedMs = nil
	m.solvedEq = ""
	m.voteSession = -1
end

local function newMember(player: Player, name: string)
	local m = { id = player.UserId, name = name, score = 0, left = false, away = false }
	resetMemberRound(m)
	return m
end

-- Removes a player from whatever lobby they are in. A departing host takes
-- the lobby with them, exactly like the web version's "host left" screen.
local function leaveCurrentLobby(userId: number)
	local code = playerLobby[userId]
	playerLobby[userId] = nil
	local lobby = code and lobbies[code]
	if not lobby then
		return
	end
	if lobby.hostId == userId then
		closeLobby(lobby, "hostLeft")
		return
	end
	local m = lobby.members[userId]
	if m then
		if lobby.status == "active" then
			m.left = true -- stays on the standings, faded
		else
			lobby.members[userId] = nil
			local i = table.find(lobby.order, userId)
			if i then
				table.remove(lobby.order, i)
			end
		end
	end
	broadcast(lobby)
end

local function puzzleFor(match, round: number)
	while #match.puzzles < round do
		table.insert(match.puzzles, Solver.generatePuzzle())
	end
	return match.puzzles[round]
end

local function startMatch(lobby)
	nextMatchId += 1
	-- anyone who left before this match is gone for good
	for id, m in lobby.members do
		if m.left then
			lobby.members[id] = nil
			local i = table.find(lobby.order, id)
			if i then
				table.remove(lobby.order, i)
			end
		end
	end
	for _, m in lobby.members do
		m.score = 0
		m.away = false
		resetMemberRound(m)
	end
	local match = {
		id = nextMatchId,
		target = lobby.target,
		puzzles = {},
		round = 1,
		roundStartAt = now() + Config.MP_LEAD_IN,
		voteSession = 0,
		voteOpenAt = 0,
		history = {},
		lastResult = nil,
		winnerId = nil,
		winnerName = nil,
		pendingResolveAt = nil,
	}
	for _ = 1, 60 do
		table.insert(match.puzzles, Solver.generatePuzzle())
	end
	lobby.match = match
	lobby.status = "active"
	broadcast(lobby)
end

-- winner == nil means the hand was skipped by vote
local function resolveRound(lobby, winner)
	local match = lobby.match
	local round = match.round
	match.pendingResolveAt = nil
	if winner then
		winner.score += 1
	end
	table.insert(match.history, {
		r = round,
		p = match.puzzles[round],
		wid = if winner then winner.id else 0,
		wn = if winner then winner.name else "",
		ms = if winner then winner.solvedMs else 0,
		eq = if winner then winner.solvedEq else "",
		skipped = winner == nil,
	})
	match.lastResult = {
		r = round,
		wid = if winner then winner.id else 0,
		wn = if winner then winner.name else "",
		ms = if winner then winner.solvedMs else 0,
		skipped = winner == nil,
	}
	for _, m in lobby.members do
		resetMemberRound(m)
	end

	-- win check: reach the target and lead by two
	local ranked = orderedMembers(lobby)
	local top = ranked[1]
	local second = if ranked[2] then ranked[2].score else 0
	if top and top.score >= match.target and (top.score - second) >= Config.MP_WIN_BY then
		lobby.status = "finished"
		match.winnerId = top.id
		match.winnerName = top.name
		broadcast(lobby)
		return
	end

	match.round = round + 1
	puzzleFor(match, match.round)
	match.roundStartAt = now() + Config.MP_ROUND_GAP
	match.voteSession = 0
	match.voteOpenAt = 0
	broadcast(lobby)
end

-- host arbitration, run for every live match
local function tickLobby(lobby)
	if lobby.status ~= "active" then
		return
	end
	local match = lobby.match
	local t = now()

	-- 1. did anybody solve it?
	if match.pendingResolveAt then
		if t < match.pendingResolveAt then
			return
		end
		local best = nil
		for _, m in lobby.members do
			if m.solvedRound == match.round and m.solvedMs then
				if not best or m.solvedMs < best.solvedMs then
					best = m
				end
			end
		end
		match.pendingResolveAt = nil
		if best then
			resolveRound(lobby, best)
			return
		end
	end

	-- 2. vote-to-skip lifecycle
	if t < match.roundStartAt then
		return
	end
	local elapsed = t - match.roundStartAt
	local vs = match.voteSession
	if vs == 0 then
		if elapsed >= Config.MP_VOTE_AFTER then
			match.voteSession = 1
			match.voteOpenAt = t
			broadcast(lobby)
		end
		return
	end
	local here = activeMembers(lobby)
	local votes = 0
	for _, m in here do
		if m.voteSession == vs then
			votes += 1
		end
	end
	if votes >= majorityNeeded(#here) then
		resolveRound(lobby, nil)
		return
	end
	if t - match.voteOpenAt >= Config.MP_VOTE_REPEAT then
		-- the vote lapsed: clear it and open a fresh one
		for _, m in lobby.members do
			m.voteSession = -1
		end
		match.voteSession = vs + 1
		match.voteOpenAt = t
		broadcast(lobby)
	end
end

RunService.Heartbeat:Connect(function()
	for _, lobby in lobbies do
		local ok, err = pcall(tickLobby, lobby)
		if not ok then
			warn("[24] lobby tick failed:", err)
		end
	end
end)

-- keep directory entries alive for long sessions
task.spawn(function()
	while true do
		task.wait(60 * 20)
		for code in lobbies do
			dirSet(code)
		end
	end
end)

---------------------------------------------------------------------------
-- requests
---------------------------------------------------------------------------
local pendingJoins = {} -- [userId] = { code, name, auto }

local handlers = {}

function handlers.hello(player: Player)
	local prof = profiles[player.UserId]
	while prof and not prof.loaded do
		task.wait(0.1)
	end
	prof = profiles[player.UserId] or loadProfile(player)
	local pending = pendingJoins[player.UserId]
	pendingJoins[player.UserId] = nil
	return {
		ok = true,
		best = prof.best,
		displayName = player.DisplayName,
		pendingJoin = pending,
	}
end

function handlers.soloStart(player: Player)
	local prof = profiles[player.UserId]
	if prof then
		prof.soloCount = 0
		prof.lastSolveAt = 0
	end
	return { ok = true }
end

function handlers.soloSolved(player: Player)
	local prof = profiles[player.UserId]
	if not prof then
		return { ok = false }
	end
	local t = os.clock()
	-- a new hand takes longer than this just to deal
	if t - prof.lastSolveAt >= 0.5 then
		prof.lastSolveAt = t
		prof.soloCount += 1
		if prof.soloCount > prof.best then
			prof.best = prof.soloCount
			prof.dirty = true
		end
	end
	return { ok = true, best = prof.best }
end

function handlers.createLobby(player: Player, name)
	leaveCurrentLobby(player.UserId)
	local clean = filterName(player, name)
	local code = genCode()
	local lobby = {
		code = code,
		hostId = player.UserId,
		status = "waiting",
		target = Config.MP_DEFAULT_TARGET,
		members = {},
		order = {},
		match = nil,
	}
	lobby.members[player.UserId] = newMember(player, clean)
	table.insert(lobby.order, player.UserId)
	lobbies[code] = lobby
	playerLobby[player.UserId] = code
	dirSet(code)
	return { ok = true, snap = snapshot(lobby) }
end

function handlers.joinLobby(player: Player, code, name)
	if typeof(code) ~= "string" then
		return { ok = false, err = "Enter the lobby code." }
	end
	code = string.upper((string.gsub(code, "%s", "")))
	if code == "" then
		return { ok = false, err = "Enter the lobby code." }
	end
	local lobby = lobbies[code]
	if not lobby then
		local entry = dirGet(code)
		if entry and entry.jobId ~= game.JobId then
			-- the lobby lives on another server: send the player there
			local clean = filterName(player, name)
			local ok, err = pcall(function()
				local opts = Instance.new("TeleportOptions")
				opts.ServerInstanceId = entry.jobId
				opts:SetTeleportData({ joinCode = code, joinName = clean })
				TeleportService:TeleportAsync(entry.placeId, { player }, opts)
			end)
			if ok then
				return { ok = false, teleporting = true, err = "Heading to that lobby's server…" }
			end
			warn("[24] teleport failed:", err)
			return { ok = false, err = "Couldn't reach that lobby's server — it may be full." }
		end
		if IS_STUDIO then
			return { ok = false, err = "No lobby with that code on this server. (Codes from other servers work in the published game.)" }
		end
		return { ok = false, err = "No lobby with that code." }
	end
	if lobby.status == "active" and not lobby.members[player.UserId] then
		return { ok = false, err = "That match is already under way — try again when it finishes." }
	end
	if playerLobby[player.UserId] ~= code then
		leaveCurrentLobby(player.UserId)
	end
	local clean = filterName(player, name)
	local m = lobby.members[player.UserId]
	if m then
		m.name = clean
		m.left = false
	else
		lobby.members[player.UserId] = newMember(player, clean)
		table.insert(lobby.order, player.UserId)
	end
	playerLobby[player.UserId] = code
	broadcast(lobby)
	return { ok = true, snap = snapshot(lobby) }
end

local function myLobby(player: Player)
	local code = playerLobby[player.UserId]
	local lobby = code and lobbies[code]
	if lobby and lobby.members[player.UserId] then
		return lobby, lobby.members[player.UserId]
	end
	return nil, nil
end

function handlers.leaveLobby(player: Player)
	leaveCurrentLobby(player.UserId)
	return { ok = true }
end

function handlers.setTarget(player: Player, v)
	local lobby = myLobby(player)
	if not lobby or lobby.hostId ~= player.UserId then
		return { ok = false }
	end
	v = math.floor(tonumber(v) or Config.MP_DEFAULT_TARGET)
	if v < 1 then
		v = Config.MP_DEFAULT_TARGET
	end
	lobby.target = math.min(Config.MP_MAX_TARGET, v)
	broadcast(lobby)
	return { ok = true, target = lobby.target }
end

function handlers.startMatch(player: Player, target)
	local lobby = myLobby(player)
	if not lobby or lobby.hostId ~= player.UserId then
		return { ok = false }
	end
	if lobby.status == "active" then
		return { ok = false }
	end
	if target ~= nil then
		handlers.setTarget(player, target)
	end
	startMatch(lobby)
	return { ok = true }
end

function handlers.claim(player: Player, round, ms, eq)
	local lobby, m = myLobby(player)
	if not lobby or lobby.status ~= "active" or not m or m.left then
		return { ok = false }
	end
	local match = lobby.match
	local t = now()
	if round ~= match.round or t < match.roundStartAt - 0.25 then
		return { ok = false }
	end
	if m.solvedRound == match.round then
		return { ok = true }
	end
	if not Solver.verifyClaim(eq, match.puzzles[match.round]) then
		return { ok = false, err = "not 24" }
	end
	-- The client measures against the shared round start; trust it, but
	-- never beyond what the server itself has seen (plus a latency credit).
	local serverMs = math.max(0, (t - match.roundStartAt) * 1000)
	local claimed = tonumber(ms) or serverMs
	if claimed ~= claimed then
		claimed = serverMs
	end
	claimed = math.clamp(claimed, math.max(0, serverMs - 2000), serverMs)
	m.solvedRound = match.round
	m.solvedMs = math.floor(claimed + 0.5)
	m.solvedEq = eq
	m.away = false
	if not match.pendingResolveAt then
		match.pendingResolveAt = t + Config.MP_RESOLVE_GRACE
	end
	return { ok = true }
end

function handlers.vote(player: Player, session)
	local lobby, m = myLobby(player)
	if not lobby or lobby.status ~= "active" or not m then
		return { ok = false }
	end
	local match = lobby.match
	if match.voteSession == 0 or session ~= match.voteSession then
		return { ok = false }
	end
	m.voteSession = match.voteSession
	m.away = false
	broadcast(lobby)
	return { ok = true }
end

-- The ✕ button mid-match: back to the lobby screen, but still in the lobby.
function handlers.away(player: Player)
	local lobby, m = myLobby(player)
	if not lobby or not m then
		return { ok = false }
	end
	if lobby.status == "active" then
		m.away = true
		broadcast(lobby)
	end
	return { ok = true, snap = snapshot(lobby) }
end

function handlers.snapshot(player: Player)
	local lobby = myLobby(player)
	if not lobby then
		return { ok = false }
	end
	return { ok = true, snap = snapshot(lobby) }
end

Request.OnServerInvoke = function(player: Player, action, ...)
	local h = typeof(action) == "string" and handlers[action]
	if not h then
		return { ok = false, err = "bad request" }
	end
	local ok, result = pcall(h, player, ...)
	if not ok then
		warn("[24] request", action, "failed:", result)
		return { ok = false, err = "Something went wrong. Try again." }
	end
	return result
end

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	task.spawn(loadProfile, player)
	-- arriving from a teleport (cross-server join) or a friend invite
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and typeof(joinData) == "table" then
		local td = joinData.TeleportData
		if typeof(td) == "table" and typeof(td.joinCode) == "string" then
			pendingJoins[player.UserId] = { code = td.joinCode, name = td.joinName, auto = true }
		elseif typeof(joinData.LaunchData) == "string" and joinData.LaunchData ~= "" then
			local code = string.upper(string.sub(joinData.LaunchData, 1, 6))
			pendingJoins[player.UserId] = { code = code, auto = false }
		end
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	pendingJoins[userId] = nil
	leaveCurrentLobby(userId)
	saveProfile(userId)
	profiles[userId] = nil
end)

game:BindToClose(function()
	for userId in profiles do
		saveProfile(userId)
	end
	for code in lobbies do
		dirRemove(code)
	end
	task.wait(1)
end)

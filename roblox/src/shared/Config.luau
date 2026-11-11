--[[
	Config — the only file you should ever need to touch.
]]

return {
	-- Sound effects. The game ships working with a built-in Roblox click as a
	-- stand-in. For the exact sounds from the web version, upload the three
	-- files in the "sounds" folder (Studio: View > Asset Manager > Import)
	-- and paste their ids here, e.g. "rbxassetid://1234567890".
	SOUND_IDS = {
		add = "", -- sounds/card-add.wav     (card settles into the equation)
		submit = "", -- sounds/submit.wav    (two-note confirmation)
		deal = "", -- sounds/deal.wav        (paper flick as a card is dealt)
	},
	SOUND_VOLUME = 1,

	-- Roblox's chat window sits where the "24" logo is and would swallow the
	-- "/" key (divide), so it is off by default.
	ENABLE_CHAT = false,

	-- Multiplayer tuning (seconds). Mirrors the web version.
	MP_DEFAULT_TARGET = 5, -- first to 5 ...
	MP_WIN_BY = 2, -- ... and clear by 2
	MP_CURTAIN = 3.3, -- ready / set / go
	MP_LEAD_IN = 7.5, -- start of match -> first hand unlocks
	MP_ROUND_GAP = 2.3, -- result banner + fade + deal between hands
	MP_VOTE_AFTER = 30, -- a hand may be voted on after 30s
	MP_VOTE_REPEAT = 120, -- a failed vote reopens every 2 minutes
	MP_RESOLVE_GRACE = 0.28, -- catch near-simultaneous answers
	MP_MAX_TARGET = 30,

	-- DataStore that keeps each player's solo best.
	BEST_STORE = "TwentyFourBest_v1",
	-- MemoryStore map that lets a lobby code be joined from another server.
	LOBBY_DIRECTORY = "TwentyFourLobbies_v1",
}

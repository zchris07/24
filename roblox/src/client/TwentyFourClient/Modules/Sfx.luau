--[[
	Sfx — the three table sounds.

	The web version synthesised these on the fly; Roblox can't, so the exact
	same sounds are rendered to sounds/*.wav. Until those are uploaded and
	their ids pasted into Config.SOUND_IDS, a short click that ships with
	every Roblox client stands in, pitched to keep the three cues distinct.
]]

local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("TwentyFour"):WaitForChild("Config"))

local FALLBACK = "rbxasset://sounds/volume_slider.ogg"

local Sfx = {}

local folder = Instance.new("Folder")
folder.Name = "TwentyFourSfx"
folder.Parent = SoundService

local templates = {}

local function make(name: string, id: string, volume: number, speed: number)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	s.Volume = volume * (Config.SOUND_VOLUME or 1)
	s.PlaybackSpeed = speed
	s.Parent = folder
	templates[name] = s
	return s
end

local ids = Config.SOUND_IDS or {}
local custom = {
	add = typeof(ids.add) == "string" and ids.add ~= "",
	submit = typeof(ids.submit) == "string" and ids.submit ~= "",
	deal = typeof(ids.deal) == "string" and ids.deal ~= "",
}

-- duller, lower "click" as a card settles into the equation
make("add", if custom.add then ids.add else FALLBACK, if custom.add then 0.9 else 0.35, if custom.add then 1 else 0.7)
-- light paper flick as a card is dealt
make("deal", if custom.deal then ids.deal else FALLBACK, if custom.deal then 0.9 else 0.3, if custom.deal then 1 else 1.7)
-- brighter two-note confirmation
make("submit", if custom.submit then ids.submit else FALLBACK, if custom.submit then 0.9 else 0.4, if custom.submit then 1 else 1.15)

task.spawn(function()
	pcall(function()
		ContentProvider:PreloadAsync(folder:GetChildren())
	end)
end)

local function fire(name: string, speed: number?)
	local t = templates[name]
	if not t then
		return
	end
	local s = t:Clone()
	if speed then
		s.PlaybackSpeed = speed
	end
	s.Parent = folder
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(3, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

function Sfx.add()
	fire("add")
end

function Sfx.deal()
	fire("deal")
end

function Sfx.submit()
	if custom.submit then
		fire("submit")
	else
		-- two rising ticks stand in for the two-note chime
		fire("submit", 1.15)
		task.delay(0.075, fire, "submit", 1.72)
	end
end

return Sfx

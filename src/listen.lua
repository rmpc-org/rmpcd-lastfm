local first_tag = require("src.util").first_tag

local MIN_TRACK_LENGTH_SECS = 30
local ALWAYS_SCROBBLE_AFTER_SECS = 4 * 60
local RESTART_WINDOW_SECS = 10

---@class Listen
---@field song QueuedSong
---@field started_at integer|nil When the song first started playing, sent as the scrobble timestamp
---@field played_secs integer How long it played before the last pause
---@field resumed_at integer|nil When it last started playing, nil while it's not playing
---@field handled boolean Whether it was already queued for scrobbling or skipped
local Listen = {}
Listen.__index = Listen

---@param song QueuedSong
---@param now integer
---@param playing boolean
---@return Listen
function Listen.new(song, now, playing)
	local listen = setmetatable({ song = song, played_secs = 0, handled = false }, Listen)
	if playing then
		listen:resume(now)
	end
	return listen
end

---@param now integer
function Listen:resume(now)
	if self.resumed_at == nil then
		self.started_at = self.started_at or now
		self.resumed_at = now
	end
end

---@param now integer
function Listen:pause(now)
	if self.resumed_at ~= nil then
		self.played_secs = self.played_secs + (now - self.resumed_at)
		self.resumed_at = nil
	end
end

---@param now integer
---@return integer
function Listen:listened_secs(now)
	if self.resumed_at == nil then
		return self.played_secs
	end
	return self.played_secs + (now - self.resumed_at)
end

---@param now integer
---@return boolean
function Listen:should_scrobble(now)
	local duration_secs = self.song.duration / 1000
	if duration_secs <= MIN_TRACK_LENGTH_SECS then
		return false
	end

	local listened_secs = self:listened_secs(now)
	return listened_secs >= ALWAYS_SCROBBLE_AFTER_SECS or listened_secs >= duration_secs / 2
end

---@param elapsed_secs number Where MPD is in the song
---@param now integer
---@return boolean
function Listen:started_over(elapsed_secs, now)
	return elapsed_secs < RESTART_WINDOW_SECS and self:listened_secs(now) - elapsed_secs > RESTART_WINDOW_SECS
end

---@return boolean
function Listen:has_required_tags()
	return first_tag(self.song.artist) ~= nil and first_tag(self.song.title) ~= nil
end

return Listen

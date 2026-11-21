local Api = require("src.api")
local auth = require("src.auth")
local Listen = require("src.listen")
local Deque = require("src.deque")

local DEFAULT_SESSION_KEY_PATH = os.getenv("HOME") .. "/.local/share/rmpcd/lastfm-session-key"

---@type LastFmPlugin
---@diagnostic disable-next-line: missing-fields
local M = {}

---@param api LastFmApi
---@param scrobble_queue Deque<{ song: Song, timestamp: integer }>
local function process_scrobble_queue(api, scrobble_queue)
	if api.session_key == nil then
		return
	end

	log.info("Processing scrobble queue with " .. (scrobble_queue.last - scrobble_queue.first + 1) .. " items")
	while true do
		local item = scrobble_queue:peek_left()
		if item == nil then
			break
		end

		local result = api:scrobble(item.song, item.timestamp)
		if result == "failed" then
			log.error("Failed to scrobble, stopping processing of scrobble queue for now")
			break
		end
		scrobble_queue:pop_left()
	end
	log.info("Finished processing scrobble queue")
end

---@param self LastFmPlugin
---@param now integer
local function queue_if_listened(self, now)
	local listen = self.listen
	if listen == nil or listen.handled or not listen:should_scrobble(now) then
		return
	end
	listen.handled = true

	if not listen:has_required_tags() then
		log.warn("Not scrobbling " .. listen.song.file .. ", it has no artist or title tag")
		return
	end

	self.scrobble_queue:push_right({ song = listen.song, timestamp = listen.started_at })
end

M.setup = function(self, args)
	self.update_now_playing = args.update_now_playing ~= false
	self.enabled = args.enabled ~= false
	self.scrobble_queue = Deque.new()
	self.api = Api.new(args.api_key, args.shared_secret)

	auth.login(self.api, args.session_key_path or DEFAULT_SESSION_KEY_PATH)
end

---@param self LastFmPlugin
---@return boolean
local function is_playing(self)
	if self.playback_state == nil then
		local status, err = mpd.get_status()
		if status == nil then
			log.error("Failed to get MPD status, assuming it's not playing: " .. tostring(err))
			return false
		end
		self.playback_state = status.state
	end
	return self.playback_state == "play"
end

---@param self LastFmPlugin
local function listen_to_current_song(self)
	local song = mpd.get_current_song()
	if song ~= nil then
		self.listen = Listen.new(song, os.time(), is_playing(self))
	end
end

---@param self LastFmPlugin
---@param song QueuedSong|nil
---@param now integer
local function replace_listen(self, song, now)
	queue_if_listened(self, now)

	if song == nil then
		self.listen = nil
	else
		self.listen = Listen.new(song, now, is_playing(self))
		if self.update_now_playing and self.api.session_key ~= nil then
			self.api:update_now_playing(self.listen)
		end
	end

	process_scrobble_queue(self.api, self.scrobble_queue)
end

M.start = function(self)
	if self.enabled then
		listen_to_current_song(self)
	end
end

M.song_change = function(self, _old, new)
	if self.enabled then
		replace_listen(self, new, os.time())
	end
end

M.idle_event = function(self, event)
	if event ~= "player" or not self.enabled or self.listen == nil then
		return
	end

	local status = mpd.get_status()
	if status == nil or status.state ~= "play" or status.song_id ~= self.listen.song.id then
		return
	end

	local now = os.time()
	if not self.listen:started_over(status.elapsed / 1000, now) then
		return
	end

	local song = mpd.get_current_song()
	if song ~= nil and song.id == self.listen.song.id and song.file == self.listen.song.file then
		replace_listen(self, song, now)
	end
end

M.state_change = function(self, _old, new)
	self.playback_state = new
	if not self.enabled or self.listen == nil then
		return
	end

	local now = os.time()
	if new == "play" then
		self.listen:resume(now)
	else
		self.listen:pause(now)
		queue_if_listened(self, now)

		if new == "stop" then
			self.listen = Listen.new(self.listen.song, now, false)
		end
	end

	process_scrobble_queue(self.api, self.scrobble_queue)
end

M.subscribed_channels = { "rmpcd.lastfm" }
M.message = function(self, _channel, message)
	local was_enabled = self.enabled
	if message == "enable" then
		log.info("Enabling lastfm plugin")
		self.enabled = true
	elseif message == "disable" then
		log.info("Disabling lastfm plugin")
		self.enabled = false
	elseif message == "toggle" then
		log.info("Toggling lastfm plugin to: " .. tostring(not self.enabled))
		self.enabled = not self.enabled
	end

	if not self.enabled then
		self.listen = nil
	elseif not was_enabled then
		listen_to_current_song(self)
	end
end

return M

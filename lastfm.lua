---@type LastFmPlugin
---@diagnostic disable-next-line: missing-fields
local M = {}

local function lastfm_api_sig(params, shared_secret)
	local keys = {}
	for k, _ in pairs(params) do
		if k ~= "format" and k ~= "callback" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)

	local base = ""
	for _, k in ipairs(keys) do
		base = base .. k .. params[k]
	end
	base = base .. shared_secret

	return util.md5(base)
end

local HTTP_TIMEOUT_MS = 10 * 1000
local AUTH_POLL_INTERVAL_MS = 10 * 1000
local AUTH_TIMEOUT_MINS = 10

-- https://www.last.fm/api/errorcodes
local LASTFM_INVALID_PARAMETERS = 6
local LASTFM_INVALID_SESSION_KEY = 9

---@param resp HttpResponse
---@return { error: integer, message: string }|nil
local function lastfm_error(resp)
	if resp.body == nil or resp.json == nil then
		return nil
	end

	local ok, body = pcall(resp.json, resp)
	if ok and type(body) == "table" and body.error ~= nil then
		return body
	end
	return nil
end

---@param resp HttpResponse
---@return string
local function describe_failure(resp)
	local err = lastfm_error(resp)
	if err ~= nil then
		return "Last.fm error " .. tostring(err.error) .. ": " .. tostring(err.message)
	end
	return resp.error or ("HTTP " .. tostring(resp.code))
end

---@param value MetadataValue|nil
---@return string|nil
local function first_tag(value)
	if value == nil or value:first() == "" then
		return nil
	end
	return value:first()
end

---@param ms integer
---@return integer
local function ms_to_secs(ms)
	return math.floor(ms / 1000)
end

---@param api_key string
---@param shared_secret string
---@param session_key string
---@param listen Listen
local function lastfm_update_now_playing(api_key, shared_secret, session_key, listen)
	local song = listen.song
	if not listen:has_required_tags() then
		log.warn("Not sending now playing for " .. song.file .. ", it has no artist or title tag")
		return
	end

	local params = {
		method = "track.updateNowPlaying",
		api_key = api_key,
		sk = session_key,
		format = "json",
		track = first_tag(song.title),
		artist = first_tag(song.artist),
		album = first_tag(song.album),
		albumArtist = first_tag(song.album_artist),
		mbid = first_tag(song.musicbrainz_track_id),
	}

	local duration_seconds = ms_to_secs(song.duration)
	if duration_seconds > 0 then
		params.duration = tostring(duration_seconds)
	end

	params.api_sig = lastfm_api_sig(params, shared_secret)

	local resp = http.post("https://ws.audioscrobbler.com/2.0/", {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if resp.code ~= 200 then
		log.error("Last.fm updateNowPlaying failed: " .. describe_failure(resp))
	end
end

---@param api_key string
---@param shared_secret string
---@param token string
---@return string|nil session_key
local function get_session_key(api_key, shared_secret, token)
	local params = {
		api_key = api_key,
		method = "auth.getSession",
		token = token,
		format = "json",
	}

	params.api_sig = lastfm_api_sig(params, shared_secret)

	local session_response = http.get("https://ws.audioscrobbler.com/2.0/", {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if session_response.code == 200 then
		return session_response:json().session.key
	end

	return nil
end

---@class Deque<T>
---@field first integer
---@field last integer
---@field [integer] T
local Deque = {}
Deque.__index = Deque

---@generic T
---@return Deque<T>
function Deque.new()
	return setmetatable({ first = 0, last = -1 }, Deque)
end

---@generic T
---@param value T
function Deque:push_right(value)
	local last = self.last + 1
	self.last = last
	self[last] = value
end

---@generic T
---@return T
function Deque:pop_left()
	local first = self.first
	if first > self.last then
		return nil
	end
	local value = self[first]
	self[first] = nil
	self.first = first + 1
	return value
end

---@generic T
---@return T
function Deque:peek_right()
	local last = self.last
	if self.first > last then
		return nil
	end
	return self[last]
end

---@generic T
---@return T
function Deque:peek_left()
	local first = self.first
	if first > self.last then
		return nil
	end
	return self[first]
end

---@alias ScrobbleResult
---| "sent"
---| "rejected"
---| "failed"

---@param api_key string
---@param session_key string
---@param shared_secret string
---@param old_song Song
---@param song_start integer
---@return ScrobbleResult
local function scrobble(api_key, session_key, shared_secret, old_song, song_start)
	local params = {
		method = "track.scrobble",
		api_key = api_key,
		sk = session_key,
		timestamp = tostring(song_start),
		format = "json",
		artist = first_tag(old_song.artist),
		album = first_tag(old_song.album),
		track = first_tag(old_song.title),
		albumArtist = first_tag(old_song.album_artist),
		mbid = first_tag(old_song.musicbrainz_track_id),
	}

	params.api_sig = lastfm_api_sig(params, shared_secret)
	local resp = http.post("https://ws.audioscrobbler.com/2.0/", {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	local err = lastfm_error(resp)
	if resp.code == 200 and err == nil then
		log.info("Scrobbled: " .. old_song.file)
		return "sent"
	end

	if err ~= nil and err.error == LASTFM_INVALID_PARAMETERS then
		log.warn("Last.fm rejected the scrobble of " .. old_song.file .. ", dropping it: " .. describe_failure(resp))
		return "rejected"
	end

	log.error("Last.fm scrobble failed: " .. describe_failure(resp))
	if err ~= nil and err.error == LASTFM_INVALID_SESSION_KEY then
		log.error("Last.fm no longer accepts the saved session key, delete it and restart rmpcd to log in again")
	end
	return "failed"
end

---@param api_key string
---@param session_key string
---@param shared_secret string
---@param scrobble_queue Deque<{ song: Song, timestamp: integer }>
local function process_scrobble_queue(api_key, session_key, shared_secret, scrobble_queue)
	if session_key == nil then
		return
	end

	log.info("Processing scrobble queue with " .. (scrobble_queue.last - scrobble_queue.first + 1) .. " items")
	while true do
		local item = scrobble_queue:peek_left()
		if item == nil then
			break
		end

		local result = scrobble(api_key, session_key, shared_secret, item.song, item.timestamp)
		if result == "failed" then
			log.error("Failed to scrobble, stopping processing of scrobble queue for now")
			break
		end
		scrobble_queue:pop_left()
	end
	log.info("Finished processing scrobble queue")
end

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

local DEFAULT_SESSION_KEY_PATH = os.getenv("HOME") .. "/.local/share/rmpcd/lastfm-session-key"

---@param path string
---@param session_key string
local function write_session_key(path, session_key)
	local parent = path:match("^(.*)/[^/]*$")
	if parent ~= nil and parent ~= "" then
		local _, dir_err = fs.create_dir_all(parent)
		if dir_err ~= nil then
			log.error("Failed to create directory for Last.fm session key: " .. dir_err)
			return
		end
	end

	local _, sk_write_err = fs.write_str(path, session_key)
	if sk_write_err ~= nil then
		log.error("Failed to write Last.fm session key to file: " .. sk_write_err)
	end
end

M.setup = function(self, args)
	self.api_key = args.api_key
	self.shared_secret = args.shared_secret
	self.update_now_playing = args.update_now_playing ~= false
	self.enabled = args.enabled ~= false
	self.session_key_path = args.session_key_path or DEFAULT_SESSION_KEY_PATH
	self.scrobble_queue = Deque.new()

	local cached_session_key, err = fs.read_str(self.session_key_path)
	if cached_session_key ~= nil and err == nil then
		cached_session_key = cached_session_key:match("^%s*(.-)%s*$")
	end
	if cached_session_key ~= nil and cached_session_key ~= "" and err == nil then
		log.info("Using cached Last.fm session key from " .. self.session_key_path)
		self.session_key = cached_session_key
		return
	else
		log.info("No cached Last.fm session key found at " .. self.session_key_path .. ", starting auth flow")
	end

	local response = http.get("https://ws.audioscrobbler.com/2.0", {
		params = {
			method = "auth.getToken",
			api_key = args.api_key,
			format = "json",
		},
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if response.code ~= 200 then
		log.error("Failed to get Last.fm auth token: " .. describe_failure(response))
		return
	end

	local token = response:json().token
	local auth_url = "https://www.last.fm/api/auth/?api_key=" .. args.api_key .. "&token=" .. token

	log.info("Allow rmpcd to access your Last.fm account at " .. auth_url)
	if util.which("xdg-open") then
		process.spawn({ "xdg-open", auth_url })
	else
		log.warn("xdg-open not found in PATH, open the link above in your browser yourself")
	end

	log.info("Waiting up to " .. AUTH_TIMEOUT_MINS .. " minutes for you to allow access in the browser")

	local give_up_at = os.time() + AUTH_TIMEOUT_MINS * 60
	local polling = true
	sync.set_interval(AUTH_POLL_INTERVAL_MS, function(handle)
		if not polling then
			return
		end

		if os.time() >= give_up_at then
			polling = false
			handle.cancel()
			log.error("Gave up waiting for Last.fm browser auth after " .. AUTH_TIMEOUT_MINS
				.. " minutes, restart rmpcd to try again")
			return
		end

		local session_key = get_session_key(args.api_key, args.shared_secret, token)
		if session_key ~= nil then
			polling = false
			handle.cancel()
			write_session_key(self.session_key_path, session_key)
			self.session_key = session_key
			log.info("Logged in to Last.fm")
		end
	end)
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
		if self.update_now_playing and self.session_key ~= nil then
			lastfm_update_now_playing(self.api_key, self.shared_secret, self.session_key, self.listen)
		end
	end

	process_scrobble_queue(self.api_key, self.session_key, self.shared_secret, self.scrobble_queue)
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

	process_scrobble_queue(self.api_key, self.session_key, self.shared_secret, self.scrobble_queue)
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

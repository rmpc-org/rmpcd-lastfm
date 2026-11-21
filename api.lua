local first_tag = require("util").first_tag

local API_URL = "https://ws.audioscrobbler.com/2.0/"
local HTTP_TIMEOUT_MS = 10 * 1000

-- https://www.last.fm/api/errorcodes
local LASTFM_INVALID_PARAMETERS = 6
local LASTFM_INVALID_SESSION_KEY = 9

---@alias ScrobbleResult
---| "sent"
---| "rejected"
---| "failed"

---@class LastFmApi
---@field api_key string
---@field shared_secret string
---@field session_key string|nil nil until the user is logged in
local Api = {}
Api.__index = Api

---@param api_key string
---@param shared_secret string
---@return LastFmApi
function Api.new(api_key, shared_secret)
	return setmetatable({ api_key = api_key, shared_secret = shared_secret }, Api)
end

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

---@param ms integer
---@return integer
local function ms_to_secs(ms)
	return math.floor(ms / 1000)
end

---@return string|nil token
function Api:get_token()
	local response = http.get(API_URL, {
		params = {
			method = "auth.getToken",
			api_key = self.api_key,
			format = "json",
		},
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if response.code ~= 200 then
		log.error("Failed to get Last.fm auth token: " .. describe_failure(response))
		return nil
	end

	local token = response:json().token
	if token == nil then
		log.error("Last.fm sent no auth token")
	end
	return token
end

---@param token string
---@return string url Where the user allows rmpcd to access their account
function Api:auth_url(token)
	return "https://www.last.fm/api/auth/?api_key=" .. self.api_key .. "&token=" .. token
end

---@param token string
---@return string|nil session_key nil until the user allowed access in the browser
function Api:get_session_key(token)
	local params = {
		api_key = self.api_key,
		method = "auth.getSession",
		token = token,
		format = "json",
	}

	params.api_sig = lastfm_api_sig(params, self.shared_secret)

	local session_response = http.get(API_URL, {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if session_response.code == 200 then
		return session_response:json().session.key
	end

	return nil
end

---@param listen Listen
function Api:update_now_playing(listen)
	local song = listen.song
	if not listen:has_required_tags() then
		log.warn("Not sending now playing for " .. song.file .. ", it has no artist or title tag")
		return
	end

	local params = {
		method = "track.updateNowPlaying",
		api_key = self.api_key,
		sk = self.session_key,
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

	params.api_sig = lastfm_api_sig(params, self.shared_secret)

	local resp = http.post(API_URL, {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	if resp.code ~= 200 then
		log.error("Last.fm updateNowPlaying failed: " .. describe_failure(resp))
	end
end

---@param song Song
---@param timestamp integer When the song started playing
---@return ScrobbleResult
function Api:scrobble(song, timestamp)
	local params = {
		method = "track.scrobble",
		api_key = self.api_key,
		sk = self.session_key,
		timestamp = tostring(timestamp),
		format = "json",
		artist = first_tag(song.artist),
		album = first_tag(song.album),
		track = first_tag(song.title),
		albumArtist = first_tag(song.album_artist),
		mbid = first_tag(song.musicbrainz_track_id),
	}

	params.api_sig = lastfm_api_sig(params, self.shared_secret)
	local resp = http.post(API_URL, {
		params = params,
		timeout_ms = HTTP_TIMEOUT_MS,
	})

	local err = lastfm_error(resp)
	if resp.code == 200 and err == nil then
		log.info("Scrobbled: " .. song.file)
		return "sent"
	end

	if err ~= nil and err.error == LASTFM_INVALID_PARAMETERS then
		log.warn("Last.fm rejected the scrobble of " .. song.file .. ", dropping it: " .. describe_failure(resp))
		return "rejected"
	end

	log.error("Last.fm scrobble failed: " .. describe_failure(resp))
	if err ~= nil and err.error == LASTFM_INVALID_SESSION_KEY then
		log.error("Last.fm no longer accepts the saved session key, delete it and restart rmpcd to log in again")
	end
	return "failed"
end

return Api

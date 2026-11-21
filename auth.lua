local AUTH_POLL_INTERVAL_MS = 10 * 1000
local AUTH_TIMEOUT_MINS = 10

local M = {}

---@param path string
---@return string|nil session_key nil when nothing usable is saved
local function read_session_key(path)
	local contents, err = fs.read_str(path)
	if contents == nil or err ~= nil then
		return nil
	end

	local session_key = contents:match("^%s*(.-)%s*$")
	if session_key == "" then
		return nil
	end
	return session_key
end

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

---@param api LastFmApi
---@param path string
function M.login(api, path)
	local saved_session_key = read_session_key(path)
	if saved_session_key ~= nil then
		log.info("Using cached Last.fm session key from " .. path)
		api.session_key = saved_session_key
		return
	end
	log.info("No cached Last.fm session key found at " .. path .. ", starting auth flow")

	local token = api:get_token()
	if token == nil then
		return
	end

	local auth_url = api:auth_url(token)
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
		-- Ticks that were already queued still run after cancel()
		if not polling then
			return
		end

		if os.time() >= give_up_at then
			polling = false
			handle.cancel()
			log.error(
				"Gave up waiting for Last.fm browser auth after "
					.. AUTH_TIMEOUT_MINS
					.. " minutes, restart rmpcd to try again"
			)
			return
		end

		local session_key = api:get_session_key(token)
		if session_key ~= nil then
			polling = false
			handle.cancel()
			write_session_key(path, session_key)
			api.session_key = session_key
			log.info("Logged in to Last.fm")
		end
	end)
end

return M

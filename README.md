Scrobble to last.fm.

## Installation

You need your own Last.fm API account. Go to <https://www.last.fm/api/account/create>, create an API
account and then put the `API key` and `Shared secret` into your `init.lua`.

```lua
---@type LastFmPlugin
local lastfm = rmpcd.install({ url = "https://github.com/rmpc-org/rmpcd-lastfm.git" })
lastfm:setup({
	api_key = "<your api key>",
	shared_secret = "<your shared secret>",
})
```

You are inside a full lua runtime here, so if you don't want to hardcode these here you can for
example read them from disk.

The plugin will open Last.fm in your browser on the first start, you have to authorize the plugin
for the application you created. It uses `xdg-open` to open the browser. The link is also in rmpcd's
log in case `xdg-open` is not installed on your machine. The plugin waits 10 minutes for you to
allow access, after that restart rmpcd to get a new link.

## Configuration

`api_key` and `shared_secret` are required, everything else is optional. The values below are the
defaults.

```lua
rmpcd.install({ url = "https://github.com/rmpc-org/rmpcd-lastfm.git" }):setup({
	api_key = "<your api key>",
	shared_secret = "<your shared secret>",
	-- Send the current song to Last.fm as "now playing"
	update_now_playing = true,
	-- Whether scrobbling is on when rmpcd starts, can be changed at runtime, see below
	enabled = true,
	-- Where the session key is saved after you log in
	session_key_path = os.getenv("HOME") .. "/.local/share/rmpcd/lastfm-session-key",
})
```

Song scrobbles only when either 4 minutes or over half of it was listened to. If the song is shorter
than 30 seconds it will not be scrobbled. These are Last.fm's requirements.

## Runtime control

Scrobbling can be turned on and off without restarting rmpcd by sending a message to the
`rmpcd.lastfm` channel, for example with rmpc:

```sh
rmpc sendmessage rmpcd.lastfm disable
rmpc sendmessage rmpcd.lastfm enable
rmpc sendmessage rmpcd.lastfm toggle
```

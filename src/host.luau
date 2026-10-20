--!strict
-- Chime's host half.
--
-- The window half decides when a sound is due. This half decides whether
-- the sound plays and plays it. It runs in the daemon on its own worker
-- thread, so file reads, TOML parsing and process spawns do not cost a
-- window its tight time budget.
--
-- The two halves share only the plugin's data directory. They talk through
-- the channel in src/shared.luau, which this half loads with loadstring:
-- require fails on the symlinked plugin files of the Nix deployment.

type Config = {
	sounds: { [string]: string },
	only_unfocused: boolean,
	min_seconds: number,
	volume: number,
}

local SERVE_EVERY_MS = 100 -- the channel is served this often
local SWEEP_EVERY_MS = 30000 -- stale channel files are swept this often
local SWEEP_MAX_AGE_S = 60 -- a channel file older than this is stale
local CONFIG_EVERY_MS = 5000 -- the configuration is re-read this often
local MIN_GAP_MS = 500 -- two sounds never follow each other faster
local MOMENT_WINDOW_S = 2 -- a moment stays claimed this long
local PLAY_TIMEOUT_MS = 15000 -- a player that runs longer is killed
local PROBE_TIMEOUT_MS = 5000 -- the player probe gets this long
local MAX_CONFIG_BYTES = 64 * 1024 -- a bigger configuration is ignored

local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local DATA_CONFIG = tern.plugin.data .. SEP .. "sounds.toml"
local PLUGIN_CONFIG = tern.plugin.dir .. SEP .. "sounds.toml"

-- The channel --------------------------------------------------------------------------------

-- The shared module is loaded with loadstring, not with require: the Nix
-- deployment links every plugin file into the plugins folder, and require
-- refuses to resolve a module that is a symlink.
local shared_ok, shared = pcall(function()
	local chunk = loadstring(tern.fs.read(tern.plugin.dir .. "/src/shared.luau"))
	if chunk == nil then
		return nil
	end
	return chunk()
end)
if not shared_ok or shared == nil then
	tern.log.error("Chime: could not load src/shared.luau: " .. tostring(shared))
	return
end

-- Run a function and report the error it raised. The error message is
-- empty when the function worked.
local function try(fn: () -> ()): (boolean, string)
	local ok, err = pcall(function(): string
		fn()
		return ""
	end)
	if ok then
		return true, ""
	end
	return false, tostring(err)
end

-- Configuration --------------------------------------------------------------------------------

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Cut a `#` comment, keeping `#` inside quotes.
local function strip_comment(line: string): string
	local in_single = false
	local in_double = false
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == "\\" and (in_single or in_double) then
			i += 2
		elseif c == "'" and not in_double then
			in_single = not in_single
			i += 1
		elseif c == '"' and not in_single then
			in_double = not in_double
			i += 1
		elseif c == "#" and not in_single and not in_double then
			return string.sub(line, 1, i - 1)
		else
			i += 1
		end
	end
	return line
end

-- A quoted value without its quotes, or nil when not quoted. Only the
-- matching quote and the backslash unescape, so Windows paths work as-is
-- in double quotes (`"C:\sounds\ping.wav"` needs no doubling).
local function unquote(s: string): string?
	if #s < 2 then
		return nil
	end
	local first = string.sub(s, 1, 1)
	if first ~= '"' and first ~= "'" then
		return nil
	end
	if string.sub(s, -1) ~= first then
		return nil
	end
	local inner = string.sub(s, 2, -2)
	if first == '"' then
		inner = string.gsub(inner, '\\"', '"')
		inner = string.gsub(inner, "\\\\", "\\")
	else
		inner = string.gsub(inner, "\\'", "'")
	end
	return inner
end

local function default_config(): Config
	local dir = tern.plugin.dir .. SEP .. "sounds"
	return {
		sounds = {
			alert = dir .. SEP .. "alert.wav",
			yield = dir .. SEP .. "yield.wav",
			done = dir .. SEP .. "done.wav",
		},
		only_unfocused = true,
		min_seconds = 30,
		volume = 100,
	}
end

local function is_absolute(p: string): boolean
	if string.sub(p, 1, 1) == "/" then
		return true
	end
	return string.match(p, "^[A-Za-z]:[\\/]") ~= nil or string.sub(p, 1, 2) == "\\\\"
end

local function resolve_path(p: string, base: string): string
	if string.sub(p, 1, 1) == "~" then
		local home = tern.getenv("HOME") or tern.getenv("USERPROFILE") or ""
		if home ~= "" then
			p = home .. string.sub(p, 2)
		end
	end
	if is_absolute(p) then
		return p
	end
	return base .. SEP .. p
end

local function parse_config(text: string, base: string): (Config, { string })
	local config = default_config()
	local problems: { string } = {}
	for raw in string.gmatch(text, "[^\r\n]+") do
		local line = trim(strip_comment(raw))
		if line ~= "" then
			local key, value = string.match(line, "^([A-Za-z_][%w_]*)%s*=%s*(.-)%s*$")
			if key == nil or value == nil or value == "" then
				table.insert(problems, "Skipping line: " .. line)
			elseif key == "alert" or key == "yield" or key == "done" then
				local quoted = unquote(value)
				if quoted == nil then
					table.insert(problems, key .. ": expected a quoted path, got " .. value)
				elseif quoted == "" then
					config.sounds[key] = ""
				else
					config.sounds[key] = resolve_path(quoted, base)
				end
			elseif key == "only_unfocused" then
				if value == "true" then
					config.only_unfocused = true
				elseif value == "false" then
					config.only_unfocused = false
				else
					table.insert(problems, "only_unfocused: expected true or false, got " .. value)
				end
			elseif key == "min_seconds" then
				local n = tonumber(value)
				if n == nil or n < 0 then
					table.insert(problems, "min_seconds: expected seconds >= 0, got " .. value)
				else
					config.min_seconds = n
				end
			elseif key == "volume" then
				local n = tonumber(value)
				if n == nil or n % 1 ~= 0 or n < 1 or n > 100 then
					table.insert(problems, "volume: expected a whole number between 1 and 100, got " .. value)
				else
					config.volume = n
				end
			else
				table.insert(problems, "Unknown key: " .. key)
			end
		end
	end
	return config, problems
end

local config = default_config()
local config_source = "(defaults)"
local config_key: string? = nil
local config_problems: { string } = {}
local warned: { [string]: boolean } = {}

-- The data-folder config wins when it reads; the shipped one is the fallback.
-- The read has no byte cap: a capped read rejects a symlink, and the Nix
-- deployment links the shipped sounds.toml into the plugins folder. The size
-- limit applies to the text after the read.
local function read_config_file(): (string?, string?)
	for _, path in { DATA_CONFIG, PLUGIN_CONFIG } do
		local ok, text = pcall(tern.fs.read, path)
		if ok and type(text) == "string" then
			if #text > MAX_CONFIG_BYTES then
				-- Too big: ignore this file, as a capped read would have.
				continue
			end
			return text :: string, path
		end
	end
	return nil, nil
end

-- Take a configuration file into use. The file is already read.
local function load_config(text: string, path: string): { string }
	local parsed, problems = parse_config(text, if path == DATA_CONFIG then tern.plugin.data else tern.plugin.dir)
	config = parsed
	config_source = path
	warned = {}
	for kind, sound in config.sounds do
		if sound ~= "" then
			local ok_exists, exists = pcall(tern.fs.exists, sound)
			if not ok_exists or not exists then
				table.insert(problems, kind .. ": file not found: " .. sound)
			end
		end
	end
	config_problems = problems
	return problems
end

-- The sound file of one kind, or an empty string when the kind is silent.
local function sound_of(kind: string): string
	local value = config.sounds[kind]
	if value == nil then
		return ""
	end
	return value
end

-- The player ------------------------------------------------------------------------------------

local linux_player: string? = nil
local linux_probe_failed = false
local linux_probing = false
local linux_queue: { string } = {}
local warned_no_player = false

-- The name of the player this host half uses, or an empty string when it
-- has none.
local function current_player(): string
	local os_name = tern.runtime.os
	if os_name == "linux" then
		return linux_player or ""
	elseif os_name == "macos" then
		return "afplay"
	elseif os_name == "windows" then
		return "wscript.exe"
	end
	return ""
end

-- The state the window half reads: the player, the source of the
-- configuration and the problems of that configuration.
local function publish_state()
	shared.publish({
		player = current_player(),
		source = config_source,
		problems = if #config_problems > 0 then config_problems else tern.json.array(),
		updated = os.time(),
	})
end

-- Read the configuration and publish the result. A file with the same text
-- as the last read keeps the current configuration.
local function refresh_config()
	local text, path = read_config_file()
	local key = if text == nil or path == nil then "" else (path :: string) .. "\n" .. text
	if key ~= config_key then
		config_key = key
		if text == nil or path == nil then
			config = default_config()
			config_source = "(defaults)"
			config_problems = {}
			warned = {}
		else
			local problems = load_config(text, path)
			if #problems > 0 then
				tern.log.warn("Chime: " .. table.concat(problems, "; "))
			end
		end
	end
	publish_state()
end

local function spawn(argv: { string }, path: string)
	local ok, err = try(function()
		tern.process.run(argv, { timeout_ms = PLAY_TIMEOUT_MS }, function(result: ProcessResult)
			if result.timed_out then
				tern.log.warn("Chime: playing " .. path .. " timed out")
			elseif result.status ~= 0 then
				local detail = if result.stderr ~= "" then result.stderr else "exit " .. tostring(result.status)
				tern.log.warn("Chime: couldn't play " .. path .. ": " .. trim(detail))
			end
		end)
	end)
	if not ok then
		tern.log.warn("Chime: couldn't start the player: " .. err)
	end
end

-- Preference order: PipeWire-native first (pw-play ships with pipewire),
-- then PulseAudio, ALSA, then the heavy/general players.
local LINUX_PLAYERS = { "pw-play", "paplay", "aplay", "ffplay", "play" }

-- Volume as a 0-1 fraction, the form pw-play, sox play and afplay take.
local function volume_fraction(volume: number): string
	return string.format("%.4g", volume / 100)
end

local function linux_argv(player: string, path: string, volume: number): { string }
	if player == "ffplay" then
		return { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", "-volume", tostring(volume), path }
	elseif player == "play" then
		return { "play", "-q", "-v", volume_fraction(volume), path }
	elseif player == "aplay" then
		-- aplay has no volume flag; it ignores the volume and plays at full volume.
		return { "aplay", "-q", path }
	elseif player == "paplay" then
		-- PulseAudio takes a volume in 1/65536ths (PA_VOLUME_NORM).
		return { "paplay", "--volume=" .. tostring(math.round(volume * 65536 / 100)), path }
	else
		return { "pw-play", "--volume=" .. volume_fraction(volume), path }
	end
end

local function probe_linux_player()
	if linux_probing or linux_probe_failed or linux_player ~= nil then
		return
	end
	linux_probing = true
	-- One probe per player would serialize N spawns; instead ask sh for the
	-- first match in preference order and read back which one answered.
	local names = table.concat(LINUX_PLAYERS, " ")
	local ok, err = try(function()
		tern.process.run(
			{ "sh", "-c", "for p in " .. names .. "; do command -v $p >/dev/null 2>&1 && { echo $p; exit 0; }; done; exit 1" },
			{ timeout_ms = PROBE_TIMEOUT_MS },
			function(result: ProcessResult)
				linux_probing = false
				local name = string.match(result.stdout, "([%w_-]+)")
				if result.status == 0 and name ~= nil and name ~= "" then
					linux_player = name
					for _, path in linux_queue do
						spawn(linux_argv(name, path, config.volume), path)
					end
				else
					linux_probe_failed = true
					tern.log.warn("Chime: no sound player found (need one of: " .. names .. ")")
				end
				linux_queue = {}
				publish_state()
			end
		)
	end)
	if not ok then
		linux_probing = false
		linux_probe_failed = true
		linux_queue = {}
		tern.log.warn("Chime: couldn't probe for a sound player: " .. err)
		publish_state()
	end
end

-- Play one sound file. The answer says whether a sound comes out. On Linux
-- the player is found first, so a sound asked for too early waits for the
-- probe and plays when it answers.
local function play_file(path: string): boolean
	local os_name = tern.runtime.os
	if os_name == "ios" then
		return false
	elseif os_name == "windows" then
		-- Via wscript (a windowless GUI host): spawning hidden PowerShell
		-- directly still flashes a console box on creation. SoundPlayer
		-- takes WAV only, and has no volume control, so `volume` is ignored
		-- here (see sounds.toml).
		spawn({ "wscript.exe", "//Nologo", tern.plugin.dir .. SEP .. "scripts" .. SEP .. "play.vbs", path }, path)
		return true
	elseif os_name == "macos" then
		spawn({ "afplay", "-v", volume_fraction(config.volume), path }, path)
		return true
	elseif os_name == "linux" then
		local player = linux_player
		if player ~= nil then
			spawn(linux_argv(player, path, config.volume), path)
			return true
		elseif not linux_probe_failed then
			table.insert(linux_queue, path)
			probe_linux_player()
			return true
		elseif not warned_no_player then
			warned_no_player = true
			tern.log.warn("Chime: silent (no Linux player; install pipewire-pulse, alsa-utils, sox or ffmpeg)")
		end
		return false
	else
		tern.log.warn("Chime: no player for " .. os_name)
		return false
	end
end

-- Mute and gap -----------------------------------------------------------------------------------

-- The mute flag lives in the key-value store, because the chrome segment
-- needs it and the chrome formatter may not touch the file system.
local function is_muted(): boolean
	local ok, value = pcall(tern.kv.get, "muted")
	return ok and value == true
end

local last_sound_at = -math.huge

-- The moments that already got a sound, with the second they got it.
--
-- Two windows can see the same event a moment apart: a pane raises an
-- alert, and every window notices. One sound must come out of that, not
-- one per window. The window half sends the moment it saw, and the first
-- window to send it plays; the others find it already taken.
local recent_moments: { [string]: number } = {}

-- True when this moment already got a sound, and remember it otherwise.
local function claim_moment(key: string): boolean
	local now = os.time()
	if recent_moments[key] ~= nil then
		return false
	end
	recent_moments[key] = now
	-- Keep the table small: the moments older than the window do not
	-- matter.
	for other, at in recent_moments do
		if now - at > MOMENT_WINDOW_S then
			recent_moments[other] = nil
		end
	end
	return true
end

-- Play the sound of one kind. The answer says whether a sound came out and
-- why not. `ignore_flags` skips the mute flag and the gap, which the test
-- sound needs.
local function play_sound(kind: string, ignore_flags: boolean, moment: string?): (boolean, string, string)
	local path = sound_of(kind)
	if path == "" then
		return false, "", "silent"
	end
	if not ignore_flags and is_muted() then
		return false, path, "muted"
	end
	local ok_exists, exists = pcall(tern.fs.exists, path)
	if not ok_exists or not exists then
		if not warned[path] then
			warned[path] = true
			tern.log.warn("Chime: " .. kind .. " sound not found: " .. path)
		end
		return false, path, "missing"
	end
	if not ignore_flags then
		if moment ~= nil and not claim_moment(moment) then
			-- Another window saw this moment first.
			return false, path, "moment"
		end
		local now = tern.now()
		if now - last_sound_at < MIN_GAP_MS then
			return false, path, "gap"
		end
		last_sound_at = now
	end
	if not play_file(path) then
		-- No player on this machine: nothing comes out.
		return false, path, "silent"
	end
	return true, path, ""
end

-- The requests -----------------------------------------------------------------------------------

-- The configuration as the window half reads it.
local function config_field(): { [string]: any }
	return {
		sounds = {
			alert = sound_of("alert"),
			yield = sound_of("yield"),
			done = sound_of("done"),
		},
		only_unfocused = config.only_unfocused,
		min_seconds = config.min_seconds,
		volume = config.volume,
	}
end

-- The problems of the configuration. An empty list stays a list.
local function problems_field(): { any }
	if #config_problems > 0 then
		return config_problems
	end
	return tern.json.array()
end

-- Answer one request from the window half.
local function handle(request: { [string]: any }): { [string]: any }?
	local op = request.op
	if type(op) ~= "string" then
		return { ok = false, error = "no op in the request" }
	end
	if op == "config" then
		refresh_config()
		return {
			ok = true,
			config = config_field(),
			source = config_source,
			problems = problems_field(),
		}
	elseif op == "play" then
		local kind = request.kind
		if type(kind) ~= "string" then
			return { ok = false, error = "play needs a kind" }
		end
		local moment: string? = nil
		if type(request.moment) == "string" then
			moment = request.moment
		end
		local played, path, reason = play_sound(kind, false, moment)
		return { ok = true, played = played, path = path, reason = reason }
	elseif op == "test" then
		local played, path, reason = play_sound("yield", true, nil)
		local exists = false
		if path ~= "" then
			local ok_exists, found = pcall(tern.fs.exists, path)
			exists = ok_exists and found
		end
		return { ok = true, played = played, path = path, exists = exists, reason = reason }
	elseif op == "status" then
		refresh_config()
		return {
			ok = true,
			config = config_field(),
			source = config_source,
			problems = problems_field(),
			player = current_player(),
		}
	end
	return { ok = false, error = "unknown op: " .. op }
end

-- The loops ---------------------------------------------------------------------------------------

-- The timer re-arms first so one bad tick can't stop the loop.
local function serve_tick(_cx: WindowCx?)
	tern.timer(SERVE_EVERY_MS, serve_tick)
	local ok, err = try(function()
		shared.serve(handle)
	end)
	if not ok then
		tern.log.warn("Chime: serving the channel failed: " .. err)
	end
end

local function sweep_tick(_cx: WindowCx?)
	tern.timer(SWEEP_EVERY_MS, sweep_tick)
	local ok, err = try(function()
		shared.sweep(shared.REQUEST_DIR, SWEEP_MAX_AGE_S)
		shared.sweep(shared.REPLY_DIR, SWEEP_MAX_AGE_S)
	end)
	if not ok then
		tern.log.warn("Chime: sweeping the channel failed: " .. err)
	end
end

local function config_tick(_cx: WindowCx?)
	tern.timer(CONFIG_EVERY_MS, config_tick)
	local ok, err = try(refresh_config)
	if not ok then
		tern.log.warn("Chime: reading the configuration failed: " .. err)
	end
end

-- Startup -----------------------------------------------------------------------------------------

refresh_config()
if tern.runtime.os == "linux" then
	-- Find the player now, so the published state names it.
	probe_linux_player()
end

tern.timer(SERVE_EVERY_MS, serve_tick)
tern.timer(SWEEP_EVERY_MS, sweep_tick)
tern.timer(CONFIG_EVERY_MS, config_tick)

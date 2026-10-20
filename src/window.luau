--!strict
-- Chime: a sound when a pane raises an unseen alert, an agent yields to you,
-- or a long shell command finishes.
--
-- This is the window half. It decides WHEN a sound is due:
--   alert  a pane's unseen-alert flag rises: a terminal bell, an agent that
--          finished or is waiting out of sight, or a pane whose program
--          exited. Tern shows one alert per pane until you look at it, so a
--          second bell while the flag stands chimes nothing new.
--   yield  an agent block leaves "working" for "idle": its turn is done and
--          control is back with you. The agent_finished event finds it.
--   done   a shell command ran longer than min_seconds and finished.
--
-- The host half decides WHETHER the sound plays and plays it. It reads
-- sounds.toml, finds a sound player, owns the mute flag and owns the claim
-- on a moment. One host half serves every window, so a chime in one window
-- no longer has to suppress the same moment's chime in another.
--
-- The two halves talk through the channel in src/shared.luau. This half
-- asks the host half to play, and the host half answers. This half holds
-- no player, reads no configuration file and keeps no claim logic. It
-- keeps the configuration the host half sent, the cached mute flag, and
-- the requests it waits for.
--
-- Triggers are for panes you are not looking at, unless only_unfocused=false.

type Config = {
	sounds: { [string]: string },
	only_unfocused: boolean,
	min_seconds: number,
	volume: number,
}

-- A request this half waits for. The kind names the sound a play request
-- asks for.
type Pending = {
	op: string,
	kind: string?,
	at: number,
	cx: WindowCx?,
}

local TICK_MS = 250
local CONFIG_EVERY_TICKS = 20 -- ask the host half for the configuration about every 5 s
local REQUEST_TIMEOUT_MS = 10000 -- a request with no answer is dropped
local SWEEP_EVERY_MS = 30000 -- stale channel files are swept this often
local SWEEP_MAX_AGE_S = 60 -- a channel file older than this is stale

local SEP = if tern.runtime.os == "windows" then "\\" else "/"

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

-- Show a toast. A window that has no context yet writes to the log.
local function toast(cx: WindowCx?, level: ToastLevel, text: string, sub: string)
	if cx == nil then
		tern.log.info("Chime: " .. text .. ": " .. sub)
		return
	end
	local ok, err = try(function()
		cx:toast(level, text, sub)
	end)
	if not ok then
		tern.log.warn("Chime: the toast failed: " .. err)
	end
end

-- The configuration ---------------------------------------------------------------------------

-- The configuration the host half sent. This half reads no file; it keeps
-- what the host half parsed. The values here are the fallbacks that hold
-- until the first answer arrives.
local config: Config = {
	sounds = { alert = "", yield = "", done = "" },
	only_unfocused = true,
	min_seconds = 30,
	volume = 100,
}
local config_source = "(defaults)"
local config_problems: { string } = {}

-- The strings of a JSON array. A decoded array comes back array-tagged, so
-- the list is read entry by entry.
local function string_list(value: any): { string }
	local out: { string } = {}
	if type(value) ~= "table" then
		return out
	end
	for _, item in value do
		if type(item) == "string" then
			table.insert(out, item)
		end
	end
	return out
end

-- Take the configuration from the host half's answer.
local function apply_config(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local raw = payload.config
	if type(raw) == "table" then
		local sounds = raw.sounds
		if type(sounds) == "table" then
			for _, kind in { "alert", "yield", "done" } do
				local value = sounds[kind]
				if type(value) == "string" then
					config.sounds[kind] = value
				end
			end
		end
		if type(raw.only_unfocused) == "boolean" then
			config.only_unfocused = raw.only_unfocused
		end
		if type(raw.min_seconds) == "number" then
			config.min_seconds = raw.min_seconds
		end
		if type(raw.volume) == "number" then
			config.volume = raw.volume
		end
	end
	if type(payload.source) == "string" then
		config_source = payload.source
	end
	config_problems = string_list(payload.problems)
end

-- The host half reports a sound file that is not there as a problem that
-- starts with the kind and ": file not found:".
local function missing_sound(problems: { string }, kind: string): boolean
	local prefix = kind .. ": file not found:"
	for _, problem in problems do
		if string.sub(problem, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- The requests --------------------------------------------------------------------------------

local pending: { [string]: Pending } = {}

-- The Reload command asks for a new configuration. The answer comes some
-- time later, so the wish waits here until an answer arrives.
local reload_wanted: WindowCx? = nil

-- Ask the host half to do something. The name is the key of the answer.
local function ask(op: string, fields: { [string]: any }, kind: string?, cx: WindowCx?): string?
	local request: { [string]: any } = { op = op }
	for key, value in fields do
		request[key] = value
	end
	local name = shared.ask(request)
	if type(name) ~= "string" then
		tern.log.warn("Chime: the request to the host half failed: " .. op)
		return nil
	end
	pending[name] = { op = op, kind = kind, at = tern.now(), cx = cx }
	return name
end

-- Ask for the configuration, unless a request for it is still on its way.
local function ask_config()
	for _, entry in pending do
		if entry.op == "config" then
			return
		end
	end
	ask("config", {}, nil, nil)
end

-- The Reload command. The answer shows the result.
local function report_reload(cx: WindowCx?)
	reload_wanted = nil
	if #config_problems == 0 then
		toast(cx, "info", "Chime", "Sounds reloaded from " .. config_source)
	else
		toast(cx, "error", "Chime", table.concat(config_problems, "\n"))
	end
end

-- Act on one answer from the host half.
local function handle_reply(entry: Pending, payload: any, cx: WindowCx?)
	if type(payload) ~= "table" then
		tern.log.warn("Chime: the host half sent an answer that is not a table")
		return
	end
	if payload.ok ~= true then
		local detail = "unknown error"
		if type(payload.error) == "string" then
			detail = payload.error
		end
		tern.log.warn("Chime: the host half refused the request: " .. detail)
		return
	end
	if entry.op == "config" then
		apply_config(payload)
		if reload_wanted ~= nil then
			report_reload(reload_wanted)
		end
	elseif entry.op == "play" then
		if payload.played ~= true then
			local reason = ""
			if type(payload.reason) == "string" then
				reason = payload.reason
			end
			tern.log.debug("Chime: no " .. (entry.kind or "") .. " sound (" .. reason .. ")")
		end
	elseif entry.op == "test" then
		local target = entry.cx or cx
		local path = ""
		if type(payload.path) == "string" then
			path = payload.path
		end
		local reason = ""
		if type(payload.reason) == "string" then
			reason = payload.reason
		end
		if reason == "missing" then
			toast(target, "error", "Chime", "Missing: " .. path)
		elseif reason == "silent" and path == "" then
			toast(target, "error", "Chime", "No yield sound configured")
		elseif payload.played == true then
			toast(target, "info", "Chime", "Playing " .. path)
		else
			toast(target, "error", "Chime", "Could not play " .. path)
		end
	end
end

-- Read the answers that arrived. A request that waits more than ten
-- seconds is dropped.
--
-- The reply directory is listed once, and only the answers that are in it
-- are read. Reading one file per pending request would make the tick grow
-- with the number of pending requests, and a tick that runs over its
-- budget is disabled until the next reload.
local function collect_replies(cx: WindowCx?)
	local now = tern.now()
	local ok, names = pcall(tern.fs.list, shared.path(shared.REPLY_DIR))
	if not ok or type(names) ~= "table" then
		names = {}
	end
	for _, name in names do
		local entry = pending[name]
		if entry ~= nil then
			local payload, status = shared.take_reply(name)
			if status == "ok" then
				pending[name] = nil
				handle_reply(entry, payload, cx)
			end
		end
	end
	-- The requests that got no answer in time are dropped.
	for name, entry in pending do
		if now - entry.at > REQUEST_TIMEOUT_MS then
			pending[name] = nil
			tern.log.debug("Chime: the host half did not answer the " .. entry.op .. " request")
			if entry.op == "config" and reload_wanted ~= nil then
				report_reload(reload_wanted)
			end
		end
	end
end

-- Mute -----------------------------------------------------------------------------------------

local is_muted = false

-- The mute flag lives in the key-value store, because the chrome segment
-- needs it and the chrome formatter may not touch the file system. The
-- host half reads the same flag before it plays.
local function refresh_muted()
	local ok, value = pcall(tern.kv.get, "muted")
	is_muted = ok and value == true
end

-- Triggers ------------------------------------------------------------------------------------

-- Ask the host half to play a sound. The host half holds the claim, the
-- mute flag and the player, so it decides whether a sound comes out. The
-- cached mute state stops this half from asking when the user muted.
local function chime(kind: string)
	if is_muted then
		return
	end
	ask("play", { kind = kind }, kind, nil)
end

local function list_agents(cx: WindowCx): { AgentBlock }
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		return agents :: { AgentBlock }
	end
	return {}
end

-- The pane an agent block runs in, and whether the user looks at it.
local function pane_focused(cx: WindowCx, pane: number): boolean
	local ok, info = pcall(function(): PaneInfo?
		return cx.session:pane(pane)
	end)
	if not ok or info == nil then
		return false
	end
	return info.focused == true
end

local alerts: { [number]: boolean } = {}
local seeded = false
local tick_count = 0

-- The agent that yielded its turn is found by the agent_finished event,
-- which arrives at once.
--
-- The agent that needs you (working -> waiting_input) raises the pane's
-- own alert flag, so the tick finds it there. Nothing lists the agents:
-- that call costs 10 to 50 ms on a busy machine, which is more than the
-- whole budget of a window handler, and a handler that runs over its
-- budget is disabled until the next reload.
local function tick_body(cx: WindowCx)
	tick_count += 1
	if tick_count % CONFIG_EVERY_TICKS == 0 then
		ask_config()
	end
	refresh_muted()
	collect_replies(cx)

	-- One candidate per pane; the alert edge wins over a same-tick yield.
	local candidates: { [number]: string } = {}
	local focused: { [number]: boolean } = {}

	local now_alerts: { [number]: boolean } = {}
	for _, pane in cx.session:panes() do
		local id = pane.pane
		local alerted = pane.alert == true
		now_alerts[id] = alerted
		focused[id] = pane.focused == true
		if seeded and alerted and not alerts[id] then
			candidates[id] = "alert"
		end
	end
	alerts = now_alerts

	for id, kind in candidates do
		if config.only_unfocused and focused[id] then
			-- You are looking at it; no chime.
		else
			chime(kind)
		end
	end
	seeded = true
end

-- The timer re-arms first so one bad tick can't stop the loop.
local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	if cx == nil then
		return
	end
	local ok, err = try(function()
		tick_body(cx :: WindowCx)
	end)
	if not ok then
		tern.log.warn("Chime tick failed: " .. err)
	end
end

-- The channel files of a window that went away stay behind otherwise.
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

tern.timer(TICK_MS, tick)
tern.timer(SWEEP_EVERY_MS, sweep_tick)

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	if ev.took_ms < config.min_seconds * 1000 then
		return
	end
	local ok, info = pcall(function(): PaneInfo?
		return cx.session:pane(ev.pane)
	end)
	if not ok or info == nil then
		return
	end
	if config.only_unfocused and info.focused then
		return
	end
	chime("done")
end)

-- An agent's turn ended: it yielded its turn.
--
-- The event arrives at once, so the yield needs no polling. Nothing here
-- lists the agents: that call costs more than the whole budget of a
-- window handler on a busy machine, and a handler that runs over its
-- budget is disabled until the next reload.
--
-- The event does not report a turn that ends while a prompt waits for the
-- agent. That case raises the pane's own alert flag, so the tick finds
-- it.
tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	local ok, err = try(function()
		if ev.result ~= "done" then
			-- The agent failed, exited or closed. The pane's alert flag
			-- covers the cases that need the user.
			return
		end
		if config.only_unfocused and pane_focused(cx, ev.pane) then
			-- You are looking at it; no chime.
			return
		end
		chime("yield")
	end)
	if not ok then
		tern.log.warn("Chime: the agent_finished handler failed: " .. err)
	end
end)

-- Palette + status ----------------------------------------------------------------------------

tern.command({
	id = "mute",
	title = "Chime: Mute / unmute",
	icon = "bell",
	run = function(cx: WindowCx)
		is_muted = not is_muted
		pcall(tern.kv.set, "muted", is_muted)
		tern.chrome.refresh()
		cx:toast("info", "Chime", if is_muted then "Muted" else "Unmuted")
	end,
})

tern.command({
	id = "test",
	title = "Chime: Play test sound",
	icon = "bell",
	run = function(cx: WindowCx)
		ask("test", {}, nil, cx)
	end,
})

tern.command({
	id = "reload",
	title = "Chime: Reload sounds",
	icon = "bell",
	run = function(cx: WindowCx)
		-- The answer comes later, so the wish waits for it.
		reload_wanted = cx
		ask_config()
	end,
})

tern.command({
	id = "diagnose",
	title = "Chime: Diagnose panes and agents",
	icon = "bell",
	run = function(cx: WindowCx)
		-- The state file names the player the host half uses.
		local state = shared.read_state()
		local player = ""
		local state_source = ""
		local state_problems: { string } = {}
		if type(state) == "table" then
			if type(state.player) == "string" then
				player = state.player
			end
			if type(state.source) == "string" then
				state_source = state.source
			end
			state_problems = string_list(state.problems)
		end
		local source = config_source
		if source == "(defaults)" and state_source ~= "" then
			source = state_source
		end
		local lines: { string } = {}
		table.insert(lines, "config: " .. source)
		table.insert(lines, "player: " .. (if player ~= "" then player else "(none)"))
		table.insert(lines, "muted: " .. tostring(is_muted))
		table.insert(lines, "only_unfocused: " .. tostring(config.only_unfocused))
		table.insert(lines, "min_seconds: " .. tostring(config.min_seconds))
		table.insert(lines, "volume: " .. tostring(config.volume) .. "%")
		for _, kind in { "alert", "yield", "done" } do
			local path = config.sounds[kind]
			local mark = "(off)"
			if path ~= "" then
				local gone = missing_sound(config_problems, kind) or missing_sound(state_problems, kind)
				mark = path .. (if gone then "  MISSING" else "")
			end
			table.insert(lines, kind .. " = " .. mark)
		end
		table.insert(lines, "")
		table.insert(lines, "panes:")
		for _, pane in cx.session:panes() do
			table.insert(
				lines,
				"  "
					.. tostring(pane.pane)
					.. " kind="
					.. tostring(pane.kind)
					.. " program="
					.. tostring(pane.program)
					.. " busy="
					.. tostring(pane.busy)
					.. " alert="
					.. tostring(pane.alert)
					.. " focused="
					.. tostring(pane.focused)
					.. " at_prompt="
					.. tostring(pane.at_prompt)
					.. " title="
					.. string.sub(pane.title, 1, 60)
			)
		end
		table.insert(lines, "")
		table.insert(lines, "agents:")
		for _, agent in list_agents(cx) do
			table.insert(
				lines,
				"  "
					.. tostring(agent.pane)
					.. " state="
					.. agent.state
					.. " command="
					.. tostring(agent.command)
					.. " model="
					.. tostring(agent.model)
			)
		end
		local out = tern.plugin.data .. SEP .. "diagnose.txt"
		local ok_write, err = try(function()
			tern.fs.write(out, table.concat(lines, "\n") .. "\n")
		end)
		if ok_write then
			cx:toast("info", "Chime", "Wrote " .. out)
		else
			cx:toast("error", "Chime", "Couldn't write " .. out .. ": " .. err)
		end
	end,
})

-- Mute is invisible otherwise; the segment shows it and clicks back to sound.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if is_muted then
		return { { text = "chime muted", icon = "bell", tone = "muted", command = "plugin.chime.mute" } }
	end
	return nil
end)

-- Startup -------------------------------------------------------------------------------------

refresh_muted()
ask_config()

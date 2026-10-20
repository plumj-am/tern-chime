--!strict
-- The channel between Chime's two halves.
--
-- Tern's API split is one-way: a host half cannot call a window half and a
-- window half cannot call a host half. The only state the two halves share
-- is the plugin's data directory, so they talk through files there.
--
-- The window half asks with a request file under chime/req/. The host half
-- answers with a reply file of the same name under chime/reply/, and
-- removes the request only after the reply is in place, so a reply that
-- exists is always a whole reply.
--
-- The host half also publishes chime/state.json: the configuration it read,
-- the mute flag and the player it found. The window half reads that file.
--
-- This module is loaded with loadstring(tern.fs.read(...)), not with
-- require: the Nix deployment symlinks every plugin file into the plugins
-- folder, and require refuses to resolve a module that is a symlink.

local M = {}

local ROOT = "chime"
local REQUEST_DIR = ROOT .. "/req"
local REPLY_DIR = ROOT .. "/reply"
local STATE_FILE = ROOT .. "/state.json"

-- A request name carries the second it was made in, so a stale file can be
-- swept by age. The counter and the token keep two windows from picking
-- the same name.
local SEQUENCE = 0
local TOKEN = string.format("%06x", math.random(0, 0xFFFFFF))
local DIRS_READY = false

M.REQUEST_DIR = REQUEST_DIR
M.REPLY_DIR = REPLY_DIR
M.STATE_FILE = STATE_FILE

function M.path(relative: string): string
	return tern.plugin.data .. "/" .. relative
end

function M.ensure_dirs()
	if DIRS_READY then
		return
	end
	-- Both halves may create the directories, and mkdir on a directory that
	-- exists fails, so every call is guarded.
	pcall(tern.fs.mkdir, M.path(ROOT))
	pcall(tern.fs.mkdir, M.path(REQUEST_DIR))
	pcall(tern.fs.mkdir, M.path(REPLY_DIR))
	DIRS_READY = true
end

-- Ask the host half to do something. Returns the name the reply will
-- carry, or nil when the request could not be written.
function M.ask(request: { [string]: any }): string?
	if type(request.op) ~= "string" then
		return nil
	end
	local encoded_ok, encoded = pcall(tern.json.encode, request)
	if not encoded_ok then
		return nil
	end
	M.ensure_dirs()
	-- The counter has no local of its own: a local would shadow the outer
	-- counter and every request would carry the same number.
	SEQUENCE = SEQUENCE + 1
	local name = string.format("%d-%d-%s-%s", os.time(), SEQUENCE, TOKEN, request.op)
	local written_ok = pcall(tern.fs.write, M.path(REQUEST_DIR .. "/" .. name), encoded)
	if not written_ok then
		return nil
	end
	return name
end

-- Read the host half's answer to a request. Returns the payload and "ok",
-- or nil and "missing" (not answered yet) or "corrupt" (half written).
function M.take_reply(name: string): (any?, string)
	local ok, text = pcall(tern.fs.read, M.path(REPLY_DIR .. "/" .. name))
	if not ok or type(text) ~= "string" then
		return nil, "missing"
	end
	local decoded_ok, payload = pcall(tern.json.decode, text)
	if not decoded_ok then
		return nil, "corrupt"
	end
	pcall(tern.fs.remove, M.path(REPLY_DIR .. "/" .. name))
	return payload, "ok"
end

-- Answer a request. The host half calls this.
function M.answer(name: string, payload: { [string]: any }): boolean
	local encoded_ok, encoded = pcall(tern.json.encode, payload)
	if not encoded_ok then
		return false
	end
	local written_ok = pcall(tern.fs.write, M.path(REPLY_DIR .. "/" .. name), encoded)
	return written_ok
end

-- Serve the requests the window half left. `handle` answers one request
-- and returns the payload to send back, or nil for no answer at all.
--
-- One request per pass. A burst of them, each with its own process or
-- file work, would share the host's 2 s budget, and a pass that runs over
-- its budget disables the hook until the next reload. The rest wait in
-- the request directory for the next pass.
function M.serve(handle: (request: { [string]: any }) -> { [string]: any }?)
	M.ensure_dirs()
	local ok, names = pcall(tern.fs.list, M.path(REQUEST_DIR))
	if not ok or type(names) ~= "table" or #names == 0 then
		return
	end
	local name = names[1]
	local path = M.path(REQUEST_DIR .. "/" .. name)
	local read_ok, text = pcall(tern.fs.read, path)
	if not read_ok or type(text) ~= "string" then
		return
	end
	local decoded_ok, request = pcall(tern.json.decode, text)
	if not decoded_ok or type(request) ~= "table" then
		-- Half a request: leave it and read it again next pass.
		return
	end
	local handled_ok, payload = pcall(handle, request)
	if not handled_ok then
		payload = { ok = false, error = tostring(payload) }
	end
	if payload ~= nil then
		M.answer(name, payload)
	end
	pcall(tern.fs.remove, path)
end

-- Publish a value the window half reads.
function M.publish(state: { [string]: any }): boolean
	local encoded_ok, encoded = pcall(tern.json.encode, state)
	if not encoded_ok then
		return false
	end
	M.ensure_dirs()
	local written_ok = pcall(tern.fs.write, M.path(STATE_FILE), encoded)
	return written_ok
end

-- Read what the host half published.
function M.read_state(): any?
	local ok, text = pcall(tern.fs.read, M.path(STATE_FILE))
	if not ok or type(text) ~= "string" then
		return nil
	end
	local decoded_ok, payload = pcall(tern.json.decode, text)
	if not decoded_ok then
		return nil
	end
	return payload
end

-- Remove the files in one directory that are older than `max_age_s`
-- seconds. A request whose window went away, or a reply nobody read, would
-- otherwise stay for ever.
function M.sweep(directory: string, max_age_s: number)
	local now = os.time()
	local ok, names = pcall(tern.fs.list, M.path(directory))
	if not ok or type(names) ~= "table" then
		return
	end
	for _, name in names do
		local made = tonumber(string.match(name, "^(%d+)-"))
		if made ~= nil and now - made > max_age_s then
			pcall(tern.fs.remove, M.path(directory .. "/" .. name))
		end
	end
end

return M

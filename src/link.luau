--!strict
-- The link between the plugin and its bridge (bridge/bridge.js): a long-running process that
-- controls playback through the official Spotify Web API. It runs on Node.js 22 or newer
-- (global fetch). Tern can only run processes to completion, so
-- the plugin and the bridge talk through files in the plugin's data directory:
--
--   now.json        bridge → plugin  Snapshot below, replaced atomically; `beat` is unix seconds.
--   lyrics.json     bridge → plugin  {v:1,id,status:"ok"|"none"|"error",synced,lines,error?};
--                                     id is the track URI ("" invalidates), lines are {t:ms,text}.
--   playlists.json  bridge → plugin  {id,items,offset,next?,error?}; id matches the command.
--   inbox/<id>.cmd  plugin → bridge  One command: `<op> <arg>`. The id starts with unix seconds;
--                                     the bridge drops commands older than 10 s and answers the
--                                     latest in the snapshot's `reply`.
--   alive           plugin → bridge  Unix seconds of the plugin's last check-in. The bridge exits
--                                     once it is 30 s old.
--
-- Ops: toggle, next, prev, seek <ms>, shuffle on|off, repeat off|all|one, volume <0-100>,
-- mute on|off, play <track|album|artist|playlist> <id>, search <query> (results go to
-- search.json as {id, query, items|error}), playlists <offset> (results go to playlists.json),
-- like on|off <spotify:track|episode:ID>, add <spotify:playlist:ID> <spotify:track|episode:ID>,
-- launch (open plain Spotify),
-- login (begin browser OAuth sign-in). Neither action happens automatically.

local link = {}

export type Track = {
   id: string,
   title: string,
   artist: string,
   album: string,
   length_ms: number?,
}

export type Snapshot = {
   v: number,
   os: string,
   beat: number,
   -- Whether the bridge is authorized with Spotify.
   app: boolean,
   -- Why the bridge can't control Spotify.
   problem: string?,
   -- Spotify authorization is needed; `login` begins browser sign-in.
   login: boolean?,
   -- Spotify is being opened.
   starting: boolean?,
   track: Track?,
   -- Whether the current track is saved to the library; absent until known or when unavailable.
   liked: boolean?,
   playing: boolean,
   position_ms: number?,
   -- Changes whenever the position jumps rather than advancing with time.
   timeline: number,
   shuffle: boolean?,
   ["repeat"]: string?,
   volume: number?,
   muted: boolean?,
   can: {
      toggle: boolean,
      next: boolean,
      prev: boolean,
      seek: boolean,
      shuffle: boolean,
      ["repeat"]: boolean,
      volume: boolean,
   },
   cover: { key: string, file: string?, url: string? }?,
   -- Stream format, only when the player reports it.
   format: string?,
   -- Where the queue came from (a playlist, album or mix name).
   source: string?,
   -- The next track in the queue, when Spotify has its details.
   next: { title: string, artist: string }?,
   queue: { { title: string, artist: string, length_ms: number? } }?,
   reply: { id: string, error: string? }?,
}

export type LyricLine = { t: number, text: string }
export type Lyrics = {
   v: number,
   id: string,
   status: "ok" | "none" | "error",
   synced: boolean,
   lines: { LyricLine },
   error: string?,
}

export type Playlist = { kind: string, id: string, title: string, detail: string, editable: boolean? }
export type Playlists = {
   id: string,
   items: { Playlist },
   offset: number,
   next: number?,
   error: string?,
}

local DATA = tern.plugin.data
local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local NOW = DATA .. SEP .. "now.json"
local LYRICS = DATA .. SEP .. "lyrics.json"
local PLAYLISTS = DATA .. SEP .. "playlists.json"
local INBOX = DATA .. SEP .. "inbox"
local ALIVE = DATA .. SEP .. "alive"

local STALE_S = 5
local CHECK_IN_EVERY_S = 10
local START_GRACE_S = 15

local function path(...: string): string
   return table.concat({ ... }, SEP)
end

function link.read(): Snapshot?
   local ok, text = pcall(tern.fs.read, NOW, 1024 * 1024)
   if not ok then
      return nil
   end
   local decoded, snap = pcall(tern.json.decode, text)
   if not decoded or type(snap) ~= "table" or snap.v ~= 1 then
      return nil
   end
   return snap :: Snapshot
end

function link.read_playlists(id: string, offset: number): Playlists?
   local ok, text = pcall(tern.fs.read, PLAYLISTS, 1024 * 1024)
   if not ok then
      return nil
   end
   local decoded, value = pcall(tern.json.decode, text)
   if not decoded or type(value) ~= "table" or value.id ~= id or value.offset ~= offset then
      return nil
   end
   return value :: Playlists
end

-- Terminal results only: missing, malformed and other-track files remain pending.
function link.read_lyrics(id: string): Lyrics?
   local ok, text = pcall(tern.fs.read, LYRICS, 1024 * 1024)
   if not ok then
      return nil
   end
   local decoded, value = pcall(tern.json.decode, text)
   if not decoded or type(value) ~= "table" or value.v ~= 1 or value.id ~= id or id == ""
      or (value.status ~= "ok" and value.status ~= "none" and value.status ~= "error")
      or type(value.synced) ~= "boolean" or type(value.lines) ~= "table"
      or #value.lines > 512 then
      return nil
   end
   if value.error ~= nil and (type(value.error) ~= "string" or #value.error > 2048) then
      return nil
   end
   if value.status == "error" and type(value.error) ~= "string" then
      return nil
   end
   if value.status ~= "ok" and (value.synced or #value.lines ~= 0) then
      return nil
   end
   if value.status == "ok" and #value.lines == 0 then
      return nil
   end
   local previous = -1
   local bytes = 0
   for index, line in value.lines do
      if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value.lines
         or type(line) ~= "table" or type(line.text) ~= "string" or #line.text > 2048
         or type(line.t) ~= "number" or line.t ~= line.t or line.t % 1 ~= 0
         or line.t < 0 or line.t > 86400000
         or (value.synced and line.t < previous) then
         return nil
      end
      bytes += #line.text
      if bytes > 256 * 1024 then
         return nil
      end
      previous = line.t
   end
   return value :: Lyrics
end

function link.fresh(snap: Snapshot?): boolean
   return snap ~= nil and os.time() - snap.beat <= STALE_S
end

-- Starting --------------------------------------------------------------------------------------

local checked_in_at = -math.huge
local started_at = -math.huge
local start_problem: string? = nil

local function tail(file: string): string?
   local ok, text = pcall(tern.fs.read, file, 64 * 1024)
   if not ok then
      return nil
   end
   local lines = {}
   for line in string.gmatch(text, "[^\r\n]+") do
      table.insert(lines, line)
   end
   if #lines == 0 then
      return nil
   end
   return table.concat(lines, "\n", math.max(1, #lines - 3))
end

-- The supported Windows desktop install; only explicit commands launch the app.
local function find_app(): (string?, string?)
   local os_name = tern.runtime.os
   if os_name ~= "windows" then
      return nil, "Spotify control currently supports Windows only (not " .. os_name .. ")."
   end
   local appdata = tern.getenv("APPDATA")
   if appdata == nil or appdata == "" then
      return nil, "APPDATA isn't set; can't locate the Spotify desktop app."
   end
   local app = path(appdata, "Spotify", "Spotify.exe")
   if tern.fs.exists(app) then
      return app, nil
   end
   return nil, "The Spotify desktop app wasn't found at " .. app .. "."
end

local function start()
   local client_id = tern.getenv("TERN_SPOTIFY_CLIENT_ID")
   if client_id == nil or #client_id ~= 32 or not string.match(client_id, "^%x+$") then
      start_problem = "Set TERN_SPOTIFY_CLIENT_ID to your Spotify developer app's 32-hex Client ID, then restart Tern."
      return
   end
   local app, why = find_app()
   if app == nil then
      start_problem = why
      return
   end
   local at = os.time()
   local node = tern.getenv("TERN_SPOTIFY_NODE") or "node"
   local argv = { node, path(tern.plugin.dir, "bridge", "bridge.js"), DATA, app, client_id }
   -- cwd outside the plugin directory: on Windows a process's cwd can't be replaced, which would
   -- block `tern plugin install --force` while the bridge runs.
   local options = { cwd = DATA }
   local ok, err = pcall(tern.process.run, argv, options, function(result: ProcessResult)
      -- A second bridge exits 0 at once; only an early failure means the bridge can't run.
      if result.status ~= 0 and os.time() - at < START_GRACE_S then
         local detail = tail(path(DATA, "bridge.log")) or (if result.stderr ~= "" then result.stderr else nil)
         start_problem = "The Spotify bridge stopped (exit " .. tostring(result.status) .. ")."
            .. (if detail then "\n" .. detail else "")
      end
   end)
   if not ok then
      start_problem = "Couldn't start the Spotify bridge: " .. tostring(err)
   end
end

-- Checks in with the bridge and starts one when none is answering. Returns why the bridge can't
-- run, when that's known.
function link.ensure(snap: Snapshot?): string?
   local now = os.time()
   if now - checked_in_at >= CHECK_IN_EVERY_S and pcall(tern.fs.write, ALIVE, tostring(now)) then
      checked_in_at = now
   end
   if link.fresh(snap) then
      start_problem = nil
      return nil
   end
   if now - started_at >= START_GRACE_S then
      started_at = now
      start_problem = nil
      start()
   end
   return start_problem
end

-- Forgets a failed start so the next `ensure` tries again.
function link.retry()
   started_at = -math.huge
   start_problem = nil
end

local counter = 0

-- Queues a command for the bridge; returns its id, which comes back in the snapshot's `reply`.
function link.send(op: string, arg: (string | number)?): string
   counter += 1
   -- Fixed-width parts, so the bridge's name sort is send order.
   local id = string.format("%d-%08d%04d", os.time(), counter, math.random(0, 9999))
   pcall(tern.fs.mkdir, INBOX)
   tern.fs.write(path(INBOX, id .. ".cmd"), op .. (if arg ~= nil then " " .. tostring(arg) else "") .. "\n")
   link.ensure(link.read())
   return id
end

-- The kv key under which the window half reports a player pane's { floating, focused }: the host
-- half only learns those from it.
function link.view_key(pane: number): string
   return "view:" .. tostring(pane)
end

export type PaneView = { floating: boolean, focused: boolean }

function link.pane_view(pane: number): PaneView
   local ok, value = pcall(tern.kv.get, link.view_key(pane))
   if ok and type(value) == "table" then
      return { floating = value.floating == true, focused = value.focused == true }
   end
   return { floating = false, focused = false }
end

-- Formatting -------------------------------------------------------------------------------------

function link.clock(ms: number?): string
   if ms == nil then
      return "–:––"
   end
   local s = math.max(0, ms // 1000)
   if s >= 3600 then
      return string.format("%d:%02d:%02d", s // 3600, s // 60 % 60, s % 60)
   end
   return string.format("%d:%02d", s // 60, s % 60)
end

function link.shorten(text: string, chars: number): string
   local length = utf8.len(text)
   if length == nil or length <= chars then
      return text
   end
   return string.sub(text, 1, (utf8.offset(text, chars) :: number) - 1) .. "…"
end

return link

--!strict
-- The player block: renders the bridge's snapshot and turns clicks and keys into commands.

local link = require("./link")
local search = require("./search")
local ui = tern.ui

type Snapshot = link.Snapshot

-- The bridge polls Spotify every two seconds; the tick keeps position and local controls smooth.
local TICK_MS = 100
local LYRICS_POLL_MS = 500
local PANEL_POLL_MS = 500
local SEEK_STEP_MS = 10000
local VOLUME_STEP = 5
-- Below this level a 5 % step is a large jump in loudness, so steps shrink to 1 %.
local FINE_VOLUME_BELOW = 10
-- How long a control shows the state it asked for before the snapshot must agree.
local EXPECT_MS = 2500
local NOTICE_MS = 4000


type Library = {
   offset: number,
   back: { number },
   waiting: string?,
   read_at: number,
   page: link.Playlists?,
   selected: number,
}
type Block = {
   cx: BlockCx,
   -- The cover sent to this pane, as the blob Tern gave back.
   cover_key: string?,
   blob: string?,
   signature: string,
   -- Open while searching.
   search: search.State?,
   panel: string?,
   library: Library?,
   focus_key: string?,
   controls: { { key: string, action: string } }?,
   -- A generic music icon (icons/spotify.svg) as this pane's blob: Tern's own chrome only takes built-in icon names.
   mark: string?,
   -- Floating while another block has focus: shows the preview (see `glance_view`).
   glance: boolean,
   -- Focus changes update presentation only; panels open through explicit actions.
   focused: boolean,
}

-- Blocks have no close hook; the tick drops panes that are gone.
local blocks: { [number]: Block } = {}
local snap: Snapshot? = nil
local bridge_problem: string? = nil
local ticking = false

-- The position the view extrapolates from, re-anchored whenever the bridge reports a jump.
local anchor = { timeline = -1, pos = 0, at = 0 }

local lyrics_id: string? = nil
local lyrics: link.Lyrics? = nil
local lyrics_read_at = -math.huge
local cover: { key: string?, bytes: string?, mime: string?, loading: string? } = {}
local expected: { [string]: { value: any, expires: number } } = {}
local notice: { text: string, expires: number }? = nil
-- Command id → the pane that sent it, to show the bridge's answer there.
local senders: { [string]: { pane: number, notice: string? } } = {}
local answered: string? = nil

-- State ---------------------------------------------------------------------------------------

-- A field as the view should show it: what a control just asked for until the bridge agrees.
local function shown(field: string, actual: any): any
   local want = expected[field]
   if want == nil then
      return actual
   end
   if want.value == actual or tern.now() > want.expires then
      expected[field] = nil
      return actual
   end
   return want.value
end

local function expect(field: string, value: any)
   expected[field] = { value = value, expires = tern.now() + EXPECT_MS }
end

local function playing(): boolean
   return shown("playing", snap ~= nil and snap.playing) == true
end

local function position(): number
   local s = snap
   if s == nil or s.track == nil then
      return 0
   end
   local pos = anchor.pos
   if playing() then
      pos += tern.now() - anchor.at
   end
   local length = s.track.length_ms
   if length then
      pos = math.min(pos, length)
   end
   return math.max(0, pos)
end

local function reanchor(pos: number)
   anchor = { timeline = anchor.timeline, pos = pos, at = tern.now() }
end

-- Poll only until the bridge publishes a terminal result for the current, connected track.
local function poll_lyrics()
   local s = snap
   local id: string? = nil
   if s and link.fresh(s) and s.app and not s.problem and not s.starting and not s.login and s.track then
      id = s.track.id
   end
   if id ~= lyrics_id then
      lyrics_id = id
      lyrics = nil
      lyrics_read_at = -math.huge
   end
   if id and id ~= "" and lyrics == nil and tern.now() - lyrics_read_at >= LYRICS_POLL_MS then
      lyrics_read_at = tern.now()
      lyrics = link.read_lyrics(id)
   end
end

local function background_lyrics(): link.Lyrics?
   local s = snap
   local value = lyrics
   if s and link.fresh(s) and s.app and s.playing and not s.problem and not s.starting and not s.login
      and s.track and value and value.id == s.track.id and value.status == "ok" then
      return value
   end
   return nil
end

-- Last timestamp at or before the actual extrapolated position; zero means the intro.
local function lyric_index(value: link.Lyrics): number
   if not value.synced then
      return 0
   end
   local pos = position()
   local first, last = 1, #value.lines
   local found = 0
   while first <= last do
      local middle = (first + last) // 2
      if value.lines[middle].t <= pos then
         found = middle
         first = middle + 1
      else
         last = middle - 1
      end
   end
   return found
end

local function say(text: string)
   notice = { text = text, expires = tern.now() + NOTICE_MS }
end

local function sniff(bytes: string, header: string?): string
   if header and string.match(header, "^image/") then
      return (string.match(header, "^[^;%s]+") :: string)
   end
   if string.sub(bytes, 1, 2) == "\xFF\xD8" then
      return "image/jpeg"
   end
   return "image/png"
end

local function load_cover(s: Snapshot)
   local c = s.cover
   if c == nil then
      cover = {}
      return
   end
   if c.key == cover.key or c.key == cover.loading then
      return
   end
   if c.file then
      local ok, bytes = pcall(tern.fs.read, c.file, 8 * 1024 * 1024)
      if ok then
         cover = { key = c.key, bytes = bytes, mime = sniff(bytes, nil) }
      end
   elseif c.url then
      local key = c.key
      cover.loading = key
      tern.fetch(c.url, { timeout_ms = 15000 }, function(result: FetchResult)
         if cover.loading ~= key then
            return
         end
         cover.loading = nil
         if result.error == nil and result.status == 200 then
            cover = { key = key, bytes = result.body, mime = sniff(result.body, result.headers["content-type"]) }
            for _, block in blocks do
               block.signature = ""
            end
         end
      end)
   end
end

local function take_reply(s: Snapshot)
   local reply = s.reply
   if reply == nil or reply.id == answered then
      return
   end
   answered = reply.id
   local sender = senders[reply.id]
   senders[reply.id] = nil
   local block = if sender then blocks[sender.pane] else nil
   if sender and not reply.error and sender.notice and block then
      say(sender.notice)
   end
   if sender and reply.error then
      expected = {}
      if block then
         block.cx:toast("error", "Spotify", reply.error)
         local library = block.library
         if library and library.waiting == reply.id then
            library.page = { id = reply.id, items = {}, offset = library.offset, error = reply.error }
            library.waiting = nil
            block.signature = ""
         end
      end
   end
end

-- Commands --------------------------------------------------------------------------------------

local function send(block: Block, op: string, arg: (string | number)?, success_notice: string?): string
   local id = link.send(op, arg)
   senders[id] = { pane = block.cx.pane, notice = success_notice }
   return id
end

local function toggle(block: Block)
   local s = snap
   if s == nil or not s.app then
      send(block, "login")
      return
   end
   if not s.can.toggle then
      return
   end
   reanchor(position())
   expect("playing", not playing())
   send(block, "toggle")
end

local function toggle_like(block: Block)
   local s = snap
   if s == nil or not link.fresh(s) or s.track == nil or s.liked == nil then
      return
   end
   local on = not shown("liked", s.liked)
   expect("liked", on)
   send(block, "like", (if on then "on " else "off ") .. s.track.id)
end

local function seek(block: Block, ms: number)
   local s = snap
   if s == nil or s.track == nil or not s.can.seek then
      return
   end
   local length = s.track.length_ms
   ms = math.max(0, if length then math.min(ms, length) else ms)
   reanchor(ms)
   send(block, "seek", math.floor(ms))
end

local function shuffle(block: Block)
   local s = snap
   if s == nil or not s.can.shuffle then
      say("Spotify doesn't offer shuffle here")
      return
   end
   local on = not shown("shuffle", s.shuffle)
   expect("shuffle", on)
   send(block, "shuffle", if on then "on" else "off")
end

local NEXT_REPEAT = { off = "all", all = "one", one = "off" }

local function cycle_repeat(block: Block)
   local s = snap
   if s == nil or not s.can["repeat"] then
      say("Spotify doesn't offer repeat here")
      return
   end
   local mode = NEXT_REPEAT[shown("repeat", s["repeat"]) or "off"] or "off"
   expect("repeat", mode)
   send(block, "repeat", mode)
end

local function no_volume(): string
   return "Nothing is playing in Spotify"
end

local function set_volume(block: Block, level: number)
   local s = snap
   if s == nil or not s.can.volume then
      say(no_volume())
      return
   end
   level = math.clamp(math.floor(level + 0.5), 0, 100)
   if shown("muted", s.muted) then
      expect("muted", false)
      send(block, "mute", "off")
   end
   expect("volume", level)
   send(block, "volume", level)
end

local function toggle_mute(block: Block)
   local s = snap
   if s == nil or not s.can.volume then
      say(no_volume())
      return
   end
   local on = not shown("muted", s.muted)
   expect("muted", on)
   send(block, "mute", if on then "on" else "off")
end


local function close_panels(block: Block)
   block.search = nil
   block.panel = nil
   block.library = nil
   block.focus_key = nil
end

local function load_playlists(block: Block, offset: number, back: { number })
   block.library = {
      offset = offset,
      back = back,
      waiting = send(block, "playlists", tostring(offset)),
      read_at = -math.huge,
      page = nil,
      selected = 1,
   }
end
local function act(block: Block, name: string)
   if name == "playpause" then
      toggle(block)
   elseif name == "next" or name == "prev" then
      send(block, name)
   elseif name == "back" then
      seek(block, position() - SEEK_STEP_MS)
   elseif name == "forward" then
      seek(block, position() + SEEK_STEP_MS)
   elseif name == "shuffle" then
      shuffle(block)
   elseif name == "repeat" then
      cycle_repeat(block)
   elseif name == "like" then
      toggle_like(block)
   elseif name == "mute" then
      toggle_mute(block)
   elseif name == "louder" or name == "quieter" then
      local level = shown("volume", snap and snap.volume) or 0
      local louder = name == "louder"
      local step = if (if louder then level < FINE_VOLUME_BELOW else level <= FINE_VOLUME_BELOW) then 1 else VOLUME_STEP
      set_volume(block, level + (if louder then step else -step))
   elseif name == "launch" or name == "login" then
      send(block, name)
   elseif name == "close" then
      close_panels(block)
   elseif name == "search" or name == "queue" or name == "playlists" or name == "add" or name == "keys" then
      if name == "add" and (snap == nil or not link.fresh(snap) or snap.track == nil) then
         return
      end
      close_panels(block)
      if name == "search" then
         block.search = search.open()
      else
         block.panel = name
         if name == "playlists" or name == "add" then
            load_playlists(block, 0, {})
         end
      end
   elseif name == "playlist-retry" then
      local library = block.library
      if library and library.waiting == nil then
         load_playlists(block, library.offset, library.back)
      end
   elseif name == "playlist-next" or name == "playlist-back" then
      local library = block.library
      if library and library.page and library.waiting == nil then
         local back = table.clone(library.back)
         if name == "playlist-next" and library.page.next then
            table.insert(back, library.offset)
            load_playlists(block, library.page.next, back)
         elseif name == "playlist-back" and #back > 0 then
            local offset = table.remove(back) :: number
            load_playlists(block, offset, back)
         end
      end
   elseif name == "retry" then
      link.retry()
      bridge_problem = link.ensure(link.read())
   end
end

local function play_item(block: Block, item: search.Item)
   send(block, "play", item.kind .. " " .. item.id)
   close_panels(block)
end

local function pick_playlist(block: Block, item: link.Playlist)
   if block.panel == "add" then
      local s = snap
      if s == nil or not link.fresh(s) or s.track == nil or item.editable ~= true then
         return
      end
      send(block, "add", item.id .. " " .. s.track.id, "Added to " .. item.title)
      close_panels(block)
   else
      play_item(block, item)
   end
end

local function invoke(block: Block, name: string, value: any)
   local index = tonumber(value)
   local st = block.search
   local library = block.library
   if name == "pick" and st and index and st.items[index] then
      play_item(block, st.items[index])
   elseif name == "playlist-pick" and library and library.page and index and library.page.items[index] then
      pick_playlist(block, library.page.items[index])
   elseif name == "volume" and index then
      set_volume(block, index)
   else
      act(block, name)
   end
end

-- View ------------------------------------------------------------------------------------------

local function with(node: Node, props: { [string]: any }): Node
   local p: { [string]: any } = node.p or {}
   for k, v in props do
      p[k] = v
   end
   node.p = p
   return node
end

local function button(key: string, icon: string, action: string, enabled: boolean, lit: boolean?): Node
   local labels = {
      prev = "Previous song (P)", next = "Next song (N)",
      playpause = if playing() then "Pause (Space)" else "Play (Space)",
      shuffle = "Shuffle (S)", ["repeat"] = "Cycle repeat (R)",
      mute = if snap and shown("muted", snap.muted) then "Unmute (M)" else "Mute (M)",
   }
   local label = labels[key] or key
   local text = if key == "prev" then "Prev" elseif key == "repeat" then "Repeat" else string.match(label, "^(%S+)") or label
   if key == "shuffle" then
      text = "Shuffle " .. (if snap and shown("shuffle", snap.shuffle) then "on" else "off")
   elseif key == "repeat" then
      text = "Repeat " .. tostring(shown("repeat", snap and snap["repeat"]) or "off")
   end
   return ui.el("button", {
      key = key,
      role = if key == "playpause" then "spotify-button spotify-button-main" else "spotify-button",
      tone = if not enabled then "muted" elseif lit then "accent" else nil,
      disabled = not enabled,
      attrs = { ["aria-label"] = label, ["data-tip"] = label },
      actions = if enabled then { click = action } else nil,
   }, { ui.node("icon", { name = icon }), ui.text(text) })
end

local function like_button(s: Snapshot): Node
   local liked = shown("liked", s.liked) == true
   return ui.el("button", {
      key = "like",
      role = "spotify-button spotify-like",
      tone = if liked then "accent" else nil,
      disabled = not link.fresh(s) or s.track == nil or s.liked == nil,
      actions = if link.fresh(s) and s.track ~= nil and s.liked ~= nil then { click = "like" } else nil,
   }, { ui.text(if liked then "Liked" else "Like") })
end

local function link_button(key: string, label: string, action: string, enabled: boolean?): Node
   local name = if key == "quieter" then "Decrease volume (− / Down)" elseif key == "louder" then "Increase volume (+ / Up)" else label
   return ui.el("button", {
      key = key,
      role = "spotify-link",
      disabled = enabled == false,
      attrs = { ["aria-label"] = name, ["data-tip"] = name },
      actions = if enabled == false then nil else { click = action },
   }, { ui.text(label) })
end

local function volume_view(s: Snapshot): Node
   local enabled = s.can.volume and s.volume ~= nil
   local level = shown("volume", s.volume)
   local muted = shown("muted", s.muted) == true
   local segments: { Node } = {}
   for value = 10, 100, 10 do
      local filled = level ~= nil and value <= level and not muted
      table.insert(segments, ui.el("button", {
         key = "volume-" .. value,
         role = if filled then "spotify-volume-segment spotify-volume-active" else "spotify-volume-segment",
         disabled = not enabled,
         actions = if enabled then { click = "volume=" .. value } else nil,
      }, { ui.text(tostring(value)), ui.text(if filled then "▮" else "▯") }))
   end
   return with(ui.row({
      button("mute", if muted then "slash-circle" else "wave", "mute", enabled, muted),
      link_button("quieter", "− volume", "quieter", enabled),
      with(ui.row(segments), { key = "volume-bar", role = "spotify-controls spotify-volume-bar" }),
      with(ui.text((if level ~= nil then tostring(level) .. "%" else "Volume unavailable") .. (if muted then " · muted" else "")), {
         key = "level", role = "spotify-level",
      }),
      link_button("louder", "+ volume", "louder", enabled),
   }), { key = "volume", role = "spotify-controls spotify-volume" })
end

local function next_source(s: Snapshot): Node
   local next_track = s.next
   local lines = {
      with(ui.text(if next_track then "Next: " .. next_track.title .. (if next_track.artist ~= "" then " · " .. next_track.artist else "")
         elseif s.queue then "Next: queue is empty" else "Next: unavailable"), { key = "next", role = "spotify-line spotify-next" }),
      with(ui.text(if s.source and s.source ~= "" then "From: " .. s.source else "Source unavailable"), { key = "source", role = "spotify-line spotify-source" }),
   }
   return with(ui.col(lines), { key = "next-source", role = "spotify-next-source" })
end

local function navigation(block: Block): Node
   local controls: { Node } = {}
   for _, entry in { { "search", "Search", "F / /" }, { "queue", "Up next", "Q" }, { "playlists", "Playlists", "L" }, { "add", "Add to playlist", "A" }, { "keys", "Keys", "?" } } do
      local active = if entry[1] == "search" then block.search ~= nil else block.panel == entry[1]
      local enabled = entry[1] ~= "add" or (snap ~= nil and link.fresh(snap) and snap.track ~= nil)
      table.insert(controls, ui.el("button", {
         key = entry[1],
         role = "spotify-link",
         disabled = not enabled,
         attrs = {
            ["aria-label"] = entry[2],
            ["data-tip"] = entry[2] .. " (" .. entry[3] .. ")",
            ["aria-expanded"] = tostring(active),
         },
         actions = if enabled then { click = entry[1] } else nil,
      }, { ui.text(entry[2]) }))
   end
   if block.search or block.panel then
      table.insert(controls, link_button("close", "Close (Esc)", "close"))
   end
   return with(ui.row(controls), { key = "navigation", role = "spotify-controls spotify-navigation" })
end

local function panel_view(block: Block): Node
   local kind = block.panel
   local title = if kind == "queue" then "Up next · read-only" elseif kind == "playlists" then "Your playlists" elseif kind == "add" then "Add to playlist" else "Keyboard shortcuts"
   local lines: { Node } = { with(ui.text(title), { key = "title", role = "spotify-panel-title" }) }
   local function status(text: string, state: string)
      table.insert(lines, ui.el("div", {
         key = "status", role = "spotify-status",
         attrs = { ["role"] = "status", ["aria-live"] = "polite", ["data-state"] = state },
      }, { ui.text(text) }))
   end
   if kind == "queue" then
      local s = snap
      if s == nil or s.starting then
         status("Loading queue…", "loading")
      elseif not link.fresh(s) or s.problem or not s.app or s.login then
         status(s.problem or "Queue unavailable. Sign in or reconnect Spotify.", "error")
         table.insert(lines, link_button("queue-login", "Sign in", "login"))
         table.insert(lines, link_button("queue-retry", "Retry connection", "retry"))
      elseif s.queue == nil then
         status("Spotify has not provided a queue.", "unavailable")
      elseif #s.queue == 0 then
         status("No upcoming songs.", "empty")
      else
         for i, item in s.queue do
            table.insert(lines, with(ui.text({
               ui.span(tostring(i) .. ". " .. item.title, "strong"),
               ui.span((if item.artist ~= "" then " · " .. item.artist else "") .. (if item.length_ms then " · " .. link.clock(item.length_ms) else ""), "muted"),
            }), { key = "queue-" .. i, role = "spotify-line spotify-queue-item" }))
         end
      end
   elseif kind == "playlists" or kind == "add" then
      local library = block.library
      local page = library and library.page
      if library == nil or library.waiting then
         status("Loading playlists…", "loading")
      elseif page and page.error then
         status(page.error .. " Sign in if access is needed, then retry.", "error")
         table.insert(lines, link_button("playlist-login", "Sign in", "login"))
         table.insert(lines, link_button("playlist-retry", "Retry playlists", "playlist-retry"))
      elseif page and library then
         if #page.items == 0 then
            status(if kind == "add" then "No editable playlists on this page." else "No playlists on this page.", "empty")
         end
         for i, item in page.items do
            local enabled = kind ~= "add" or (snap ~= nil and link.fresh(snap) and snap.track ~= nil)
            table.insert(lines, ui.el("button", {
               key = "playlist-" .. i,
               role = if library.selected == i then "spotify-line spotify-result spotify-selected" else "spotify-line spotify-result",
               disabled = not enabled,
               attrs = { ["aria-label"] = (if kind == "add" then "Add to playlist " else "Play playlist ") .. item.title .. (if item.detail ~= "" then " · " .. item.detail else ""), ["data-tip"] = (if kind == "add" then "Add to " else "Play playlist ") .. item.title },
               actions = if enabled then { click = "playlist-pick=" .. i } else nil,
            }, { ui.text({ ui.span(item.title, "strong"), ui.span(if item.detail ~= "" then " · " .. item.detail else "", "muted") }) }))
         end
         table.insert(lines, with(ui.row({
            link_button("playlist-back", "Previous page", "playlist-back", #library.back > 0),
            with(ui.text("From item " .. tostring(library.offset + 1)), { key = "offset", role = "spotify-page-offset" }),
            link_button("playlist-next", "Next page", "playlist-next", page.next ~= nil),
         }), { key = "pages", role = "spotify-controls spotify-pages" }))
      end
   else
      for i, text in {
         "Tab / Shift+Tab: choose control · Enter: activate",
         "Space / K: play or pause · P / N: previous / next",
         "← / →: seek 10 seconds · 0–9: seek to 0–90%",
         "+ / − or ↑ / ↓: volume · M: mute · bar: 10–100%",
         "S: shuffle · R: repeat · H: like / unlike · O: open Spotify",
         "F / /: search · Q: up next · L: playlists · A: add to playlist · ?: keys",
         "Search: type, ↑ / ↓ select, Enter plays",
         "Playlists: ↑ / ↓ select, Enter plays, ← / → pages",
         "Add to playlist: ↑ / ↓ select, Enter adds, ← / → pages",
         "Sign in again to grant library / playlist permissions",
         "Esc or Close: dismiss without playing",
      } do
         table.insert(lines, with(ui.text(text), { key = "hint-" .. i, role = "spotify-key-hint" }))
      end
   end
   return with(ui.col(lines), { key = "panel", role = "spotify-panel", attrs = { ["aria-label"] = title } })
end

local MARK_SVG: string? = (function()
   local ok, svg = pcall(tern.fs.read, "icons/spotify.svg", 16 * 1024)
   return if ok then svg else nil
end)()

local function mark_node(block: Block, key: string): Node?
   if block.mark == nil and MARK_SVG then
      block.mark = block.cx:blob(MARK_SVG :: string, "image/svg+xml")
   end
   if block.mark == nil then
      return nil
   end
   return with(ui.node("image", { blob = block.mark, alt = "Music" }), { key = key, role = "spotify-mark" })
end

local function message(block: Block, title: string, body: string, buttons: { Node }, tone: string?): Node
   local children: { Node } = {}
   local mark = mark_node(block, "mark")
   if mark then
      table.insert(children, mark)
   end
   table.insert(children, with(ui.text({ ui.span(title, "strong"), ui.span("  " .. body, "muted") }), { key = "text", role = "spotify-line" }))
   for _, b in buttons do
      table.insert(children, b)
   end
   return with(ui.row(children), { key = "message", role = "spotify-message", tone = tone })
end

local function cover_node(block: Block, s: Snapshot): Node
   if block.blob and s.cover and block.cover_key == s.cover.key then
      return with(ui.node("image", { blob = block.blob, alt = (s.track :: link.Track).album }), {
         key = "cover",
         role = "spotify-cover",
      })
   end
   local mark = mark_node(block, "cover")
   if mark then
      return with(ui.row({ mark }), { key = "cover", role = "spotify-cover spotify-cover-empty" })
   end
   return with(ui.row({ ui.node("icon", { name = "wave" }) }), { key = "cover", role = "spotify-cover spotify-cover-empty" })
end

-- Two lines beside the cover: title and controls, then the timeline.
local function now_playing(block: Block, s: Snapshot): Node
   local track = s.track :: link.Track
   local label: { Span } = { ui.span(track.title, "strong") }
   if track.artist ~= "" then
      table.insert(label, ui.span(" · " .. track.artist, "muted"))
   end

   -- Controls Spotify doesn't offer here are left out rather than greyed.
   local controls: { Node } = {
      button("prev", "frame-prev", "prev", s.can.prev),
      -- Not keyed or named "toggle": that is a Tern UI event name, and clicks on such a node never
      -- reached the block.
      button("playpause", if playing() then "pause" else "play", "playpause", s.can.toggle),
      button("next", "frame-next", "next", s.can.next),
      like_button(s),
   }
   if s.can.shuffle then
      table.insert(controls, button("shuffle", "swap", "shuffle", true, shown("shuffle", s.shuffle) == true))
   end
   if s.can["repeat"] then
      table.insert(controls, button("repeat", "repeat", "repeat", true, (shown("repeat", s["repeat"]) or "off") ~= "off"))
   end

   local pos = position()
   local length = track.length_ms
   local timeline = with(ui.row({
      with(ui.text({ ui.span(link.clock(pos), "muted") }), { key = "at", role = "spotify-time" }),
      with(ui.progress(if length and length > 0 then pos / length else 0, ""), { key = "bar", role = "spotify-bar" }),
      with(ui.text({ ui.span(link.clock(length), "muted") }), { key = "length", role = "spotify-time" }),
   }), { key = "timeline", role = "spotify-timeline" })

   return with(ui.row({
      cover_node(block, s),
      with(ui.col({
         with(ui.row({
            with(ui.row({
               mark_node(block, "mark") or ui.text(""),
               with(ui.text(label), { key = "label", role = "spotify-line" }),
            }), { key = "heading", role = "spotify-heading" }),
            with(ui.row(controls), { key = "controls", role = "spotify-controls" }),
         }), { key = "top", role = "spotify-top" }),
         timeline,
         volume_view(s),
         next_source(s),
      }), { key = "body", role = "spotify-body" }),
   }), { key = "player", role = "spotify-player" })
end

-- Keep playback, volume and context available in the compact unfocused floating player.
local function glance_view(block: Block, s: Snapshot): Node
   local track = s.track :: link.Track
   local function line(key: string, spans: { Span }): Node
      return with(ui.text(spans), { key = key, role = "spotify-line" })
   end

   local lines: { Node } = {
      with(ui.row({
         with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "spotify-line" }),
         -- Tern can show a floating card enlarged without focusing it; playback stays one click away.
         with(ui.row({
            button("prev", "frame-prev", "prev", s.can.prev),
            button("playpause", if playing() then "pause" else "play", "playpause", s.can.toggle),
            button("next", "frame-next", "next", s.can.next),
            like_button(s),
         }), { key = "controls", role = "spotify-controls" }),
      }), { key = "top", role = "spotify-top" }),
   }
   local byline: { Span } = {}
   if track.artist ~= "" then
      table.insert(byline, ui.span(track.artist))
   end
   if track.album ~= "" then
      table.insert(byline, ui.span((if #byline > 0 then " · " else "") .. track.album, "muted"))
   end
   if #byline > 0 then
      table.insert(lines, line("byline", byline))
   end

   local pos = position()
   local length = track.length_ms
   table.insert(lines, with(ui.row({
      with(ui.text({ ui.span(link.clock(pos), "muted") }), { key = "at", role = "spotify-time" }),
      with(ui.progress(if length and length > 0 then pos / length else 0, ""), { key = "bar", role = "spotify-bar" }),
      with(ui.text({ ui.span(link.clock(length), "muted") }), { key = "length", role = "spotify-time" }),
   }), { key = "timeline", role = "spotify-timeline" }))

   local facts: { Span } = {}
   local function fact(text: string?)
      if text and text ~= "" then
         table.insert(facts, ui.span((if #facts > 0 then " · " else "") .. text, "dim"))
      end
   end
   fact(s.format)
   if s.shuffle then
      fact("shuffle")
   end
   if s["repeat"] and s["repeat"] ~= "off" then
      fact("repeat " .. s["repeat"])
   end
   if #facts > 0 then
      table.insert(lines, line("facts", facts))
   end

   table.insert(lines, volume_view(s))
   table.insert(lines, next_source(s))

   return with(ui.row({
      cover_node(block, s),
      with(ui.col(lines), { key = "body", role = "spotify-body" }),
   }), { key = "glance", role = "spotify-player spotify-glance" })
end

local function scene(children: { Node }): Node
   local layers: { Node } = {
      with(ui.col(children), { key = "foreground", role = "spotify-foreground" }),
   }
   local value = background_lyrics()
   if value then
      local active = lyric_index(value)
      local lines: { Node } = {}
      for slot = 1, 3 do
         local index = if value.synced then active + slot - 2 else slot
         local line = value.lines[index]
         local text = if line then line.text else ""
         local highlighted = value.synced and active > 0 and index == active
         table.insert(lines, with(ui.text({ ui.span(if text == "" then "\u{a0}" else text) }), {
            key = "lyric-" .. tostring(slot),
            role = if highlighted then "spotify-lyric spotify-lyric-active" else "spotify-lyric",
         }))
      end
      table.insert(layers, with(ui.col(lines), { key = "lyrics", role = "spotify-lyrics" }))
   end
   -- BlockView's root is not a DOM node: its role belongs to the full main region.
   return with(ui.col(layers), { role = "spotify-scene" })
end

-- Tern routes Tab to the block input, so keep control navigation in the block as well.
local function collect_controls(block: Block, node: Node, controls: { { key: string, action: string } })
   local props = node.p
   local action = props and props.actions and props.actions.click
   if props and not props.disabled and type(action) == "string" and type(props.key) == "string" then
      table.insert(controls, { key = props.key, action = action })
      if block.focus_key == props.key then
         props.role = (props.role or "") .. " spotify-key-focus"
      end
   end
   if node.c then
      for _, child in node.c do
         collect_controls(block, child, controls)
      end
   end
end

local function view(block: Block): BlockView
   local s = snap
   local main: Node
   if bridge_problem and not link.fresh(s) then
      main = message(block, "Bridge not running", bridge_problem, { link_button("retry", "Retry", "retry") }, "error")
   elseif s == nil then
      main = message(block, "Spotify", "Connecting…", {})
   elseif s.login or not s.app then
      main = message(block, "Sign in to Spotify", s.problem or "Authorize Tern in your browser.", { link_button("login", "Sign in", "login") })
   elseif s.starting then
      main = message(block, "Opening Spotify", "", {})
   elseif s.problem then
      main = message(block, "Can't reach Spotify", s.problem, { link_button("retry", "Retry", "retry") }, "warning")
   elseif s.track == nil then
      main = message(block, "Nothing playing", "", { link_button("launch", "Open", "launch") })
   elseif block.glance then
      main = glance_view(block, s)
   else
      main = now_playing(block, s)
   end
   local children: { Node } = { main, navigation(block) }
   if block.search then
      table.insert(children, search.view(block.search))
   elseif block.panel then
      table.insert(children, panel_view(block))
   end
   local result: BlockView = { main = scene(children) }
   if notice then
      result.dock = ui.col({ with(ui.text({ ui.span(notice.text, "muted") }), { key = "notice" }) })
   end
   local controls: { { key: string, action: string } } = {}
   collect_controls(block, result.main :: Node, controls)
   block.controls = controls
   if block.focus_key then
      local found = false
      for _, control in controls do
         if control.key == block.focus_key then
            found = true
            break
         end
      end
      if not found then
         block.focus_key = nil
      end
   end
   return result
end

-- What the view depends on; panes re-render only when it changes.
local function signature(): string
   local s = snap
   local parts = { if notice then notice.text else "", bridge_problem or "", tostring(playing()), tostring(link.fresh(s)) }
   local value = background_lyrics()
   table.insert(parts, if value then value.status .. ":" .. tostring(lyric_index(value)) else "lyrics-hidden")
   table.insert(parts, if lyrics then lyrics.status else "lyrics-pending")
   if s then
      local beat = s.beat
      s.beat = 0
      table.insert(parts, tern.json.encode(s))
      s.beat = beat
      if playing() then
         table.insert(parts, tostring(position() // 1000))
      end
   end
   for field, want in expected do
      table.insert(parts, field .. "=" .. tostring(want.value))
   end
   return table.concat(parts, "\u{1f}")
end

-- Loop ------------------------------------------------------------------------------------------

local function tick()
   local live: { [number]: boolean } = {}
   for _, pane in tern.pane.list() do
      live[pane.pane] = true
   end
   for pane in blocks do
      if not live[pane] then
         blocks[pane] = nil
      end
   end
   if next(blocks) == nil then
      ticking = false
      return
   end

   local latest = link.read()
   bridge_problem = link.ensure(latest)
   if latest and (link.fresh(latest) or snap == nil) then
      if (if snap and snap.track then snap.track.id else nil) ~= (if latest.track then latest.track.id else nil) then
         expected["liked"] = nil
      end
      snap = latest
      if latest.timeline ~= anchor.timeline then
         anchor = { timeline = latest.timeline, pos = latest.position_ms or 0, at = tern.now() }
      end
      load_cover(latest)
      take_reply(latest)
   end
   poll_lyrics()
   if notice and tern.now() > notice.expires then
      notice = nil
   end

   local sig = signature()
   for _, block in blocks do
      if cover.key and cover.bytes and block.cover_key ~= cover.key then
         block.blob = block.cx:blob(cover.bytes :: string, cover.mime or "image/png")
         block.cover_key = cover.key
         block.signature = ""
      end
      if block.search and search.poll(block.search, function(op, arg)
         return send(block, op, arg)
      end) then
         block.signature = ""
      end
      local library = block.library
      if (block.panel == "playlists" or block.panel == "add") and library and library.waiting and tern.now() - library.read_at >= PANEL_POLL_MS then
         library.read_at = tern.now()
         local page = link.read_playlists(library.waiting, library.offset)
         if page then
            if block.panel == "add" then
               local editable: { link.Playlist } = {}
               for _, item in page.items do
                  if item.editable == true then
                     table.insert(editable, item)
                  end
               end
               page.items = editable
            end
            library.page = page
            library.waiting = nil
            block.signature = ""
         end
      end
      local pane_view = link.pane_view(block.cx.pane)
      local glance = pane_view.floating and not pane_view.focused
      if pane_view.focused ~= block.focused then
         block.focused = pane_view.focused
         block.signature = ""
      end
      if glance ~= block.glance then
         block.glance = glance
         -- Entering compact presentation dismisses panels; returning never opens them.
         if glance then
            close_panels(block)
         end
         block.signature = ""
      end
      local block_sig = if block.search then sig .. "\u{1f}" .. search.signature(block.search) else sig
      block_sig ..= "\u{1f}" .. (block.panel or "")
      if block.library then
         block_sig ..= "\u{1f}" .. tostring(block.library.selected)
      end
      if glance then
         block_sig ..= "\u{1f}glance"
      end
      if block.signature ~= block_sig then
         block.signature = block_sig
         block.cx:render()
      end
   end
   tern.timer(TICK_MS, tick)
end

tern.block.define("player", {
   init = function(cx: BlockCx, _args: { string }, _saved: any): Block
      local pane_view = link.pane_view(cx.pane)
      local block: Block = {
         cx = cx,
         signature = "",
         glance = pane_view.floating and not pane_view.focused,
         focused = pane_view.focused,
      }
      blocks[cx.pane] = block
      snap = snap or link.read()
      if not ticking then
         ticking = true
         tern.timer(0, tick)
      end
      return block
   end,

   title = function(_block: Block): string?
      local s = snap
      if s and s.app and s.track then
         local track = s.track :: link.Track
         local text = link.shorten(track.title, 40)
         if track.artist ~= "" then
            text ..= " · " .. link.shorten(track.artist, 30)
         end
         return (if playing() then "▶ " else "⏸ ") .. text
      end
      return "Spotify"
   end,

   view = function(block: Block, _cx: BlockCx): BlockView
      return view(block)
   end,

   key = function(block: Block, key: Key, _cx: BlockCx): boolean?
      if key.name ~= "tab" and key.name ~= "enter" and block.focus_key then
         block.focus_key = nil
         block.signature = ""
      end
      if key.ctrl or key.alt or key.meta then
         return false
      end
      if key.name == "tab" or (key.name == "enter" and block.focus_key) then
         view(block)
         local controls = block.controls or {}
         local selected = 0
         for i, control in controls do
            if control.key == block.focus_key then
               selected = i
               break
            end
         end
         if key.name == "tab" and #controls > 0 then
            if selected == 0 then
               selected = if key.shift then #controls else 1
            else
               selected = (selected - 1 + (if key.shift then -1 else 1)) % #controls + 1
            end
            block.focus_key = controls[selected].key
         elseif selected > 0 then
            local action = controls[selected].action
            local name, value = string.match(action, "^([^=]+)=(.*)$")
            block.focus_key = nil
            invoke(block, name or action, value)
         end
         block.signature = ""
         return true
      end
      if key.name == "escape" or key.name == "esc" then
         close_panels(block)
         block.signature = ""
         return true
      end
      local st = block.search
      if st then
         local result = search.key(st, key)
         if result == "close" then
            block.search = nil
         elseif type(result) == "table" then
            play_item(block, result :: search.Item)
         end
         -- Unhandled search keys still control playback.
         if result ~= false then
            block.signature = ""
            return true
         end
      end
      local library = block.library
      if (block.panel == "playlists" or block.panel == "add") and library then
         local page = library.page
         if key.name == "up" or key.name == "down" then
            library.selected = math.clamp(library.selected + (if key.name == "down" then 1 else -1), 1, math.max(1, if page then #page.items else 0))
         elseif key.name == "enter" and page and page.items[library.selected] then
            pick_playlist(block, page.items[library.selected])
         elseif key.name == "left" or key.name == "right" then
            act(block, if key.name == "left" then "playlist-back" else "playlist-next")
         else
            library = nil
         end
         if library then
            block.signature = ""
            return true
         end
      end
      local s = snap
      local typed = key.text or key.name
      if typed == "/" or typed == "f" then
         close_panels(block)
         block.search = search.open(typed)
         block.signature = ""
         return true
      end
      if typed == "q" or typed == "l" or typed == "a" or typed == "?" then
         act(block, if typed == "q" then "queue" elseif typed == "l" then "playlists" elseif typed == "a" then "add" else "keys")
         block.signature = ""
         return true
      end
      if key.name == "space" or typed == "k" then
         act(block, "playpause")
      elseif key.name == "left" then
         act(block, "back")
      elseif key.name == "right" then
         act(block, "forward")
      elseif typed == "n" then
         act(block, "next")
      elseif typed == "p" then
         act(block, "prev")
      elseif typed == "s" then
         act(block, "shuffle")
      elseif typed == "r" then
         act(block, "repeat")
      elseif typed == "h" then
         act(block, "like")
      elseif typed == "+" or typed == "=" or key.name == "up" then
         act(block, "louder")
      elseif typed == "-" or key.name == "down" then
         act(block, "quieter")
      elseif typed == "m" then
         act(block, "mute")
      elseif typed == "o" then
         act(block, "launch")
      elseif string.match(typed, "^%d$") and s and s.track and s.track.length_ms then
         seek(block, (tonumber(typed) :: number) / 10 * s.track.length_ms)
      else
         return false
      end
      return true
   end,

   event = function(block: Block, ev: UiEvent, _cx: BlockCx)
      if ev.ev == "action" and type(ev.act) == "string" then
         block.focus_key = nil
         invoke(block, ev.act, ev.value)
         block.signature = ""
      end
   end,
})

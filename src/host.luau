--!strict
-- The player block: renders the bridge's snapshot and turns clicks and keys into commands.

local link = require("./link")
local search = require("./search")
local ui = tern.ui

type Snapshot = link.Snapshot

-- The bridge publishes within milliseconds of a change; the tick is what bounds the view's lag.
local TICK_MS = 100
local SEEK_STEP_MS = 10000
local VOLUME_STEP = 5
-- Below this level a 5 % step is a large jump in loudness, so steps shrink to 1 %.
local FINE_VOLUME_BELOW = 10
-- How long a control shows the state it asked for before the snapshot must agree.
local EXPECT_MS = 2500
local NOTICE_MS = 4000

type Block = {
   cx: BlockCx,
   -- The cover sent to this pane, as the blob Tern gave back.
   cover_key: string?,
   blob: string?,
   signature: string,
   -- Open while searching.
   search: search.State?,
   -- A generic music icon (icons/spotify.svg) as this pane's blob: Tern's own chrome only takes built-in icon names.
   mark: string?,
   -- Floating while another block has focus: shows the preview (see `glance_view`).
   glance: boolean,
   -- Whether the pane had focus at the last tick, to open search when it gains it.
   focused: boolean,
}

-- Blocks have no close hook; the tick drops panes that are gone.
local blocks: { [number]: Block } = {}
local snap: Snapshot? = nil
local bridge_problem: string? = nil
local ticking = false

-- The position the view extrapolates from, re-anchored whenever the bridge reports a jump.
local anchor = { timeline = -1, pos = 0, at = 0 }

local cover: { key: string?, bytes: string?, mime: string?, loading: string? } = {}
local expected: { [string]: { value: any, expires: number } } = {}
local notice: { text: string, expires: number }? = nil
-- Command id → the pane that sent it, to show the bridge's answer there.
local senders: { [string]: number } = {}
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
   local pane = senders[reply.id]
   senders[reply.id] = nil
   if pane and reply.error then
      expected = {}
      local block = blocks[pane]
      if block then
         block.cx:toast("error", "Spotify", reply.error)
      end
   end
end

-- Commands --------------------------------------------------------------------------------------

local function send(block: Block, op: string, arg: (string | number)?): string
   local id = link.send(op, arg)
   senders[id] = block.cx.pane
   return id
end

local function toggle(block: Block)
   local s = snap
   if s == nil or not s.app then
      send(block, "launch")
      return
   end
   if not s.can.toggle then
      return
   end
   reanchor(position())
   expect("playing", not playing())
   send(block, "toggle")
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
   elseif name == "mute" then
      toggle_mute(block)
   elseif name == "louder" or name == "quieter" then
      local level = shown("volume", snap and snap.volume) or 0
      local louder = name == "louder"
      local step = if (if louder then level < FINE_VOLUME_BELOW else level <= FINE_VOLUME_BELOW) then 1 else VOLUME_STEP
      set_volume(block, level + (if louder then step else -step))
   elseif name == "launch" or name == "relaunch" then
      send(block, name)
   elseif name == "search" then
      block.search = block.search or search.open()
   elseif name == "retry" then
      link.retry()
      bridge_problem = link.ensure(link.read())
   end
end

local function play_item(block: Block, item: search.Item)
   send(block, "play", item.kind .. " " .. item.id)
   block.search = nil
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
   local props: { [string]: any } = {
      key = key,
      role = if key == "playpause" then "spotify-button spotify-button-main" else "spotify-button",
      tone = if not enabled then "muted" elseif lit then "accent" else nil,
   }
   if enabled then
      props.actions = { click = action }
   end
   return with(ui.row({ ui.node("icon", { name = icon }) }), props)
end

local function link_button(key: string, label: string, action: string): Node
   return with(ui.badge(label, "accent"), { key = key, role = "spotify-link", actions = { click = action } })
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
   }
   if s.can.shuffle then
      table.insert(controls, button("shuffle", "swap", "shuffle", true, shown("shuffle", s.shuffle) == true))
   end
   if s.can["repeat"] then
      table.insert(controls, button("repeat", "repeat", "repeat", true, (shown("repeat", s["repeat"]) or "off") ~= "off"))
   end
   local level = shown("volume", s.volume)
   if s.can.volume and level then
      local muted = shown("muted", s.muted) == true
      table.insert(controls, button("mute", if muted then "slash-circle" else "wave", "mute", true, muted))
      table.insert(controls, with(ui.text({ ui.span(if muted then "mute" else tostring(level), "muted") }), {
         key = "level",
         role = "spotify-level",
      }))
   end
   if block.search == nil then
      -- Says that search exists and which key opens it; clicking opens it too.
      table.insert(controls, with(ui.row({
         ui.node("icon", { name = "search" }),
         ui.text({ ui.span("f", "key") }),
      }), { key = "search", role = "spotify-search-hint", actions = { click = "search" } }))
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
      }), { key = "body", role = "spotify-body" }),
   }), { key = "player", role = "spotify-player" })
end

-- A floating player without focus. Tern keeps the card a few lines tall, so it fills them: cover
-- beside title, artist · album, the timeline with times, then the stream format and what plays
-- next. Nothing to click (Tern gives presses on an unfocused floating block to its card, which
-- focuses it).
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
   if s.volume then
      fact(if s.muted then "muted" else "vol " .. tostring(s.volume))
   end
   if #facts > 0 then
      table.insert(lines, line("facts", facts))
   end

   local next_track = s.next
   if next_track then
      table.insert(lines, line("next", {
         ui.span("next ", "dim"),
         ui.span(next_track.title),
         ui.span(if next_track.artist ~= "" then " · " .. next_track.artist else "", "muted"),
      }))
   elseif s.source then
      table.insert(lines, line("source", { ui.span("from ", "dim"), ui.span(s.source :: string, "muted") }))
   end

   return with(ui.row({
      cover_node(block, s),
      with(ui.col(lines), { key = "body", role = "spotify-body" }),
   }), { key = "glance", role = "spotify-player spotify-glance" })
end

local function view(block: Block): BlockView
   local s = snap
   local main: Node
   if bridge_problem and not link.fresh(s) then
      main = message(block, "Bridge not running", bridge_problem, { link_button("retry", "Retry", "retry") }, "error")
   elseif s == nil then
      main = message(block, "Spotify", "Connecting…", {})
   elseif s.starting then
      main = message(block, "Starting Spotify", "with remote control…", {})
   elseif s.relaunch then
      main = message(block, "Restart needed", "Spotify is running without remote control.", { link_button("relaunch", "Restart Spotify", "relaunch") }, "warning")
   elseif s.problem then
      main = message(block, "Can't reach Spotify", s.problem, { link_button("retry", "Retry", "retry") }, "warning")
   elseif not s.app then
      main = message(block, "Spotify isn't running", "", { link_button("launch", "Open", "launch") })
   elseif s.track == nil then
      main = message(block, "Nothing playing", "", { link_button("launch", "Open", "launch") })
   elseif block.glance then
      return { main = ui.col({ glance_view(block, s) }) }
   else
      main = now_playing(block, s)
   end
   local st = block.search
   local result: BlockView = { main = ui.col(if st then { main, search.view(st) } else { main }) }
   if notice then
      result.dock = ui.col({ with(ui.text({ ui.span(notice.text, "muted") }), { key = "notice" }) })
   end
   return result
end

-- What the view depends on; panes re-render only when it changes.
local function signature(): string
   local s = snap
   local parts = { if notice then notice.text else "", bridge_problem or "", tostring(playing()) }
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
      snap = latest
      if latest.timeline ~= anchor.timeline then
         anchor = { timeline = latest.timeline, pos = latest.position_ms or 0, at = tern.now() }
      end
      load_cover(latest)
      take_reply(latest)
   end
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
      local pane_view = link.pane_view(block.cx.pane)
      local glance = pane_view.floating and not pane_view.focused
      if pane_view.focused ~= block.focused then
         block.focused = pane_view.focused
         -- Focusing the player opens search; leaving it closes an untouched one.
         if pane_view.focused then
            block.search = block.search or search.open()
         elseif block.search and block.search.query == "" then
            block.search = nil
         end
         block.signature = ""
      end
      if glance ~= block.glance then
         block.glance = glance
         -- A glance drops search; focusing the player again starts from the full view.
         if glance then
            block.search = nil
         end
         block.signature = ""
      end
      local block_sig = if block.search then sig .. "\u{1f}" .. search.signature(block.search) else sig
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
      if key.ctrl or key.alt or key.meta then
         return false
      end
      local st = block.search
      if st then
         local result = search.key(st, key)
         if result == "close" then
            block.search = nil
         elseif type(result) == "table" then
            play_item(block, result :: search.Item)
         end
         -- Search opens with focus, so keys it leaves alone (space on an empty query, ←→) still
         -- drive the player.
         if result ~= false then
            block.signature = ""
            return true
         end
      end
      local s = snap
      local typed = key.text or key.name
      if typed == "/" or typed == "f" then
         block.search = block.search or search.open(typed)
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
         local st = block.search
         local index = tonumber(ev.value)
         if ev.act == "pick" and st and index and st.items[index] then
            play_item(block, st.items[index])
         else
            act(block, ev.act)
         end
         block.signature = ""
      end
   end,
})

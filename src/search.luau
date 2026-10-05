--!strict
-- Search in the player block: a query line and one line per result. Results follow the typing from
-- the third character on; ↑↓ pick, Enter plays, Esc closes. The bridge runs Spotify's own search
-- inside the app and writes the results to search.json.

local link = require("./link")
local ui = tern.ui

local search = {}

-- Searches start at this many characters (Enter searches shorter queries too)...
local MIN_CHARS = 3
-- ...once typing has paused this long, so a burst of keys sends one search.
local TYPE_PAUSE_MS = 150
local RESULTS = tern.plugin.data .. (if tern.runtime.os == "windows" then "\\" else "/") .. "search.json"

export type Item = { kind: string, id: string, title: string, detail: string, length_s: number? }

export type State = {
   -- The key that opened search, and when (see `search.open`).
   trigger: string?,
   opened_at: number,
   query: string,
   -- Typing goes to the query; otherwise keys move through the results.
   editing: boolean,
   typed_at: number,
   -- Search even below MIN_CHARS (Enter on a short query).
   force: boolean,
   -- The query last sent, and the command id its results come back under.
   sent: string,
   waiting: string?,
   -- Order of every search sent, so a late answer to an older one never replaces a newer one.
   order: { [string]: number },
   shown: number,
   items: { Item },
   selected: number,
   error: string?,
}

-- `trigger` is the character of the key that opened search: Tern can deliver that key's text right
-- after the key itself, and it must not land in the query.
function search.open(trigger: string?): State
   return {
      trigger = trigger,
      opened_at = tern.now(),
      query = "",
      editing = true,
      typed_at = 0,
      force = false,
      sent = "",
      waiting = nil,
      order = {},
      shown = 0,
      items = {},
      selected = 1,
      error = nil,
   }
end

local sent_count = 0

-- Sends the query once typing pauses, and picks up results that arrived. Returns true when the
-- view changed.
function search.poll(st: State, send: (op: string, arg: string) -> string): boolean
   local query = string.match(st.query, "^%s*(.-)%s*$") :: string
   local long_enough = st.force or (utf8.len(query) or #query) >= MIN_CHARS
   if query ~= st.sent and long_enough and tern.now() - st.typed_at >= TYPE_PAUSE_MS then
      st.sent = query
      st.force = false
      sent_count += 1
      local id = send("search", query)
      st.order[id] = sent_count
      st.waiting = id
      return true
   end
   if query == "" and #st.items > 0 then
      st.sent, st.items, st.waiting, st.error = "", {}, nil, nil
      return true
   end
   if st.waiting == nil then
      return false
   end
   local ok, text = pcall(tern.fs.read, RESULTS, 1024 * 1024)
   if not ok then
      return false
   end
   local decoded, result = pcall(tern.json.decode, text)
   if not decoded or type(result) ~= "table" then
      return false
   end
   -- Results for an earlier query still show while the latest one is on its way.
   local rank = st.order[result.id]
   if rank == nil or rank <= st.shown then
      return false
   end
   st.shown = rank
   if result.id == st.waiting then
      st.waiting = nil
   end
   st.error = result.error
   st.items = result.items or {}
   st.selected = math.clamp(st.selected, 1, math.max(1, #st.items))
   return true
end

local function drop_last_char(text: string): string
   local last = utf8.offset(text, -1)
   return if last then string.sub(text, 1, last - 1) else ""
end

-- Handles a key; returns "close", an item to play, true when handled, or false.
function search.key(st: State, key: Key): (string | Item | boolean)
   local name = key.name
   -- Without results, ↑↓ have nothing to move through: they stay the player's volume keys.
   if (name == "up" or name == "down") and #st.items == 0 then
      return false
   end
   if name == "escape" or name == "esc" then
      return "close"
   elseif name == "enter" then
      local item = st.items[st.selected]
      local query = string.match(st.query, "^%s*(.-)%s*$") :: string
      if item and query == st.sent then
         return item
      end
      -- Results are for another query, or none were asked for yet: search now.
      st.force = query ~= ""
      st.typed_at = 0
      return true
   elseif name == "down" or (not st.editing and key.text == "j") then
      st.editing = false
      st.selected = math.min(st.selected + 1, math.max(1, #st.items))
      return true
   elseif name == "up" or (not st.editing and key.text == "k") then
      st.selected = math.max(1, st.selected - 1)
      return true
   elseif name == "backspace" then
      st.editing = true
      st.query = drop_last_char(st.query)
      st.typed_at = tern.now()
      return true
   end
   local text = key.text or (if name == "space" then " " else nil)
   -- An empty query has nothing to separate: space stays play/pause.
   if text == " " and st.query == "" then
      return false
   end
   if text and text ~= "" and not key.ctrl and not key.alt and not key.meta then
      if text == st.trigger and st.query == "" and tern.now() - st.opened_at < 200 then
         st.trigger = nil
         return true
      end
      st.editing = true
      st.query ..= text
      st.selected = 1
      st.typed_at = tern.now()
      return true
   end
   return false
end

local function with(node: Node, props: { [string]: any }): Node
   local p: { [string]: any } = node.p or {}
   for k, v in props do
      p[k] = v
   end
   node.p = p
   return node
end

local KIND = { track = "♪", album = "◎", artist = "☺", playlist = "≡" }

function search.view(st: State): Node
   local short = (utf8.len(st.query) or #st.query) < MIN_CHARS
   local status = if st.waiting then "searching…"
      elseif st.error then st.error
      elseif st.sent ~= "" and #st.items == 0 then "no results"
      elseif short and #st.items == 0 then "results from 3 letters · enter searches now"
      else "esc closes"
   local lines: { Node } = {
      with(ui.text({
         ui.span("/ ", "dim"),
         ui.span(st.query .. (if st.editing then "▏" else ""), "strong"),
         ui.span("   " .. status, "dim"),
      }), { key = "query", role = "spotify-line spotify-query" }),
   }
   for i, item in st.items do
      local spans: { Span } = {
         ui.span((KIND[item.kind] or "·") .. " ", "dim"),
         ui.span(item.title, if i == st.selected then "strong" else nil),
      }
      if item.detail ~= "" then
         table.insert(spans, ui.span(" · " .. item.detail, "muted"))
      end
      if item.length_s then
         table.insert(spans, ui.span("  " .. link.clock(item.length_s * 1000), "dim"))
      end
      table.insert(lines, with(ui.text(spans), {
         key = "r" .. i,
         role = if i == st.selected then "spotify-line spotify-result spotify-selected" else "spotify-line spotify-result",
         tone = if i == st.selected then "accent" else nil,
         actions = { click = "pick=" .. i },
      }))
   end
   return with(ui.col(lines), { key = "search", role = "spotify-search" })
end

function search.signature(st: State): string
   local parts = { st.query, tostring(st.editing), tostring(st.selected), st.waiting or "", st.error or "", st.sent, tostring(st.shown) }
   return table.concat(parts, "\u{1f}")
end

return search

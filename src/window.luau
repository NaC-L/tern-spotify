--!strict
-- Window side: palette commands and the now-playing status segment.

local link = require("./link")

local KIND = "spotify.player"
local TICK_MS = 1000

local function open_player(cx: WindowCx)
   for _, pane in cx.session:panes() do
      if pane.block == KIND then
         cx.layout:focus(pane.pane)
         return
      end
   end
   local pane = cx:new_block(KIND, nil, "beside")
   if pane == nil then
      cx:toast("error", "Spotify isn't loaded on this host", "Install the plugin where your panes run.")
      return
   end
   -- A small picture in picture in the corner, out of the way of the work.
   cx.layout:float(pane, nil, "br")
end

tern.command({ id = "open", title = "Spotify: Open player", icon = "wave", run = open_player })

if tern.runtime.os == "ios" then
   return
end

-- Command id → whether this window sent it, to toast the bridge's answer here.
local mine: { [string]: boolean } = {}
local answered: string? = nil

local function command(id: string, title: string, icon: string, op: string)
   tern.command({
      id = id,
      title = title,
      icon = icon,
      run = function(_cx: WindowCx)
         mine[link.send(op)] = true
      end,
   })
end

command("toggle", "Spotify: Play/Pause", "play", "toggle")
command("next", "Spotify: Next track", "frame-next", "next")
command("previous", "Spotify: Previous track", "frame-prev", "prev")

local segment: StatusSegment? = nil

local function segment_of(snap: link.Snapshot?): StatusSegment?
   if not (snap and link.fresh(snap) and snap.app and snap.track) then
      return nil
   end
   local track = snap.track :: link.Track
   local text = link.shorten(track.title, 32)
   if track.artist ~= "" then
      text ..= " · " .. link.shorten(track.artist, 24)
   end
   return {
      text = text,
      icon = if snap.playing then "play" else "pause",
      tone = if snap.playing then nil else "muted",
      command = "plugin.spotify.open",
   }
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
   return if segment then { segment :: StatusSegment } else nil
end)

local function tick(cx: WindowCx?)
   local snap = link.read()
   link.ensure(snap)
   local reply = snap and snap.reply
   if cx and reply and reply.id ~= answered then
      answered = reply.id
      if mine[reply.id] then
         mine[reply.id] = nil
         if reply.error then
            cx:toast("error", "Spotify", reply.error)
         end
      end
   end
   local next_segment = segment_of(snap)
   local a, b = next_segment, segment
   if (a == nil) ~= (b == nil) or (a and b and (a.text ~= b.text or a.icon ~= b.icon)) then
      segment = next_segment
      tern.chrome.refresh()
   end
   tern.timer(TICK_MS, tick)
end

tern.timer(TICK_MS, tick)

-- Only the window knows whether a player floats and whether it has focus; it tells the host half
-- through the shared kv store, per pane. The host shows a glance (preview) while floating without
-- focus; search opens only through an explicit action.
local VIEW_CHECK_MS = 250
local published: { [number]: string } = {}

local function is_player(pane: PaneInfo): boolean
   return pane.block == KIND or pane.block == "plugin." .. KIND
end

local function publish_views(cx: WindowCx)
   local seen: { [number]: boolean } = {}
   for _, pane in cx.session:panes() do
      if is_player(pane) then
         local floating, focused = pane.floating == true, pane.focused == true
         local key = tostring(floating) .. tostring(focused)
         seen[pane.pane] = true
         if published[pane.pane] ~= key then
            published[pane.pane] = key
            pcall(tern.kv.set, link.view_key(pane.pane), { floating = floating, focused = focused })
         end
      end
   end
   for pane in published do
      if not seen[pane] then
         published[pane] = nil
         pcall(tern.kv.set, link.view_key(pane), nil)
      end
   end
end

tern.on("focus", function(_event: FocusEvent, cx: WindowCx)
   publish_views(cx)
end)

local function view_tick(cx: WindowCx?)
   if cx then
      publish_views(cx)
   end
   tern.timer(VIEW_CHECK_MS, view_tick)
end

tern.timer(VIEW_CHECK_MS, view_tick)

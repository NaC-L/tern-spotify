# Spotify for Tern

A floating player for the Windows Spotify desktop app inside [Tern](https://stencil.so/tern):
cover art, playback controls, keyboard shortcuts, search, and the current track in the status line.
It uses the app's existing sign-in, without a separate OAuth flow or exporting credentials.

## Requirements

- Windows and the Spotify desktop app installed at `%APPDATA%\Spotify\Spotify.exe`.
  Other operating systems and install locations are currently unsupported.
- [Node.js](https://nodejs.org/) **22 or newer**, with global `WebSocket` and `fetch`.
  The plugin runs `node` from PATH. To use another executable, set `TERN_SPOTIFY_NODE`
  to its full path in the environment that starts Tern.
- Spotify signed in and running with its localhost DevTools port enabled.

## Install

Install directly from GitHub:

```powershell
tern plugin install https://github.com/NaC-L/tern-spotify
```

For development, run this inside your local checkout to link it instead of copying it:

```powershell
tern plugin link .
```

Both commands reload Tern's plugins. Run **Spotify: Open player** from the command palette.
The player opens as a picture in picture in the lower-right corner; dock it like any block.
Clicking the Spotify status segment focuses or opens the player.

## Enable Spotify remote control

The plugin never silently restarts Spotify. If it is already running without remote control,
the player shows **Restart needed** and offers **Restart Spotify**. Clicking that button explicitly
requests a restart; it can interrupt playback. **Open** launches the app when it is stopped.
Merely loading the plugin starts its bridge, not Spotify.

To enable remote control manually, first quit Spotify completely, including its tray process,
then run this PowerShell command:

```powershell
& "$env:APPDATA/Spotify/Spotify.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=9228
```

The bridge connects to `127.0.0.1:9228` and the Spotify player page over Chrome DevTools Protocol.
Normal Spotify launches may omit these flags; the plugin will again show that a restart is needed.
There is no automatic playback-resume guarantee after restarting.

**Security:** a DevTools port gives other programs on your computer access to the signed-in Spotify
page, including control of playback and access to session data. Keep it bound to localhost;
do not forward or expose port 9228 to a network. Quit Spotify and reopen it without the debug
flags when you no longer want remote control. This plugin does not write or export access tokens,
cookies, or credentials. Spotify requests use its own authenticated page context.

## Controls

The following keys control the player when they are not being used to type a search query:

| Key | Action |
| --- | --- |
| `space`, `k` | Play / pause |
| `left`, `right` | Back / forward 10 seconds |
| `0`-`9` | Jump to 0-90% |
| `n`, `p` | Next / previous track |
| `s`, `r` | Shuffle / cycle repeat (off, all, one) |
| `+`, `-`, `up`, `down` | Spotify volume +/-5% (+/-1% below 10%) |
| `m` | Mute |
| `o` | Open Spotify |
| `/`, `f` | Search |

Focusing the player opens search. An unfocused floating player shows a cover-and-track preview.
Unsupported controls are unavailable rather than simulated. Format, source and next-track details
are shown only when Spotify supplies them; missing next-track data does not mean the queue has ended.

Search lists tracks, albums, artists and playlists after a brief typing pause, starting at three
characters. `Enter` searches shorter queries too. `up` / `down` select a result; `Enter` or a click
plays it using Spotify's own playback actions, replacing the playback context. `Esc` closes search.
With an empty query, `space` still controls playback; without results, `up` / `down` still change volume.

Palette commands: **Spotify: Open player**, **Spotify: Play/Pause**, **Spotify: Next track**,
and **Spotify: Previous track**.

## Internals and troubleshooting

`bridge/bridge.js` runs in Node; `bridge/spotify-page.js` runs inside Spotify's player page.
The bridge exits after the plugin's check-in is 30 seconds old. The reference file protocol is
preserved in Tern's plugin data directory:

- `now.json`: version-1 snapshot, heartbeat, actual control capabilities, and command reply.
- `inbox/<id>.cmd`: one `<op> <arg>` command; stale commands older than 10 seconds are discarded.
- `alive`: plugin check-in timestamp in Unix seconds.
- `search.json`: search command id, query, and results or an error.
- `bridge.log`: bridge diagnostics.

The protocol is documented in `src/link.luau`. `tern plugin list` reports plugin load problems.
If the bridge fails to start, check Node's version/PATH or `TERN_SPOTIFY_NODE`; if remote control is
unavailable, use the explicit restart action or the manual debug command above. Spotify desktop
updates can change its internal page interfaces, so compatibility is not guaranteed across versions.

Verified locally with Tern **0.4.5**, Spotify desktop **1.3.3.264**, and Node **22.20.0**:
floating and docked player rendering, cover art, play/pause, seek, next/previous, volume, search,
and playing a selected search result. Bridge smoke checks also exercised duplicate startup,
hard-kill recovery, heartbeat shutdown, out-of-order searches, invalid numeric commands,
and rejection of non-Spotify cover URLs.
Heartbeat shutdown also disposes the page polling interval; a new bridge reattaches successfully.

## Attribution

Ported from [H4vC/tern-CDP-tidal](https://github.com/H4vC/tern-CDP-tidal), retaining its Luau player,
search, floating preview, status segment, and file-command protocol. `icons/spotify.svg` is an original,
generic music-note icon, not an official Spotify logo. This is an unofficial plugin, not affiliated
with Spotify.

The upstream repository has no license file. This adaptation is published with the author's
permission; no blanket redistribution license for the upstream-derived code is implied.

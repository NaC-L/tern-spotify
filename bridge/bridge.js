// Spotify Web API bridge. Run with Node >=22:
//   node bridge.js <data-dir> <Spotify.exe> <client-id>
// File protocol matches src/link.luau. Sign-in and opening Spotify only happen on explicit commands.
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const childProcess = require('child_process');
const crypto = require('crypto');

const [data, executable, clientId] = process.argv.slice(2);
if (!data || !executable || !/^[0-9a-f]{32}$/i.test(clientId || '')
	|| process.platform !== 'win32' || Number(process.versions.node.split('.')[0]) < 22) {
	console.error('Usage: Node >=22 on Windows: node bridge.js <data-dir> <Spotify.exe> <32-hex client-id>');
	process.exit(2);
}
const appExe = path.resolve(executable);
const INBOX = path.join(data, 'inbox');
const TOKEN_FILE = path.join(data, 'token.json');
const API = 'https://api.spotify.com/v1';
const ACCOUNTS = 'https://accounts.spotify.com';
const LRCLIB = 'https://lrclib.net/api/get';
const USER_AGENT = 'tern-spotify/0.2.0 (https://github.com/NaC-L/tern-spotify)';
const REDIRECT_PORT = 8974;
const REDIRECT_URI = 'http://127.0.0.1:' + REDIRECT_PORT + '/callback';
// playlist-read-*: list playlists; library/playlist-modify scopes enable Like and Add to playlist.
const SCOPES = 'user-read-playback-state user-read-currently-playing user-modify-playback-state playlist-read-private playlist-read-collaborative user-library-read user-library-modify playlist-modify-public playlist-modify-private';
const COMMAND_MAX_AGE_S = 10;
const ORPHAN_AFTER_S = 30;
const HEARTBEAT_MS = 1000;
const POLL_MS = 2000;
const AFTER_COMMAND_MS = 400;
const LAUNCH_GRACE_MS = 20000;
const LOGIN_TIMEOUT_MS = 5 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 8000;
const LYRICS_TIMEOUT_MS = 10000;
// Short rate limits keep the last state on screen; longer ones are reported.
const QUIET_RATE_LIMIT_MS = 30000;
const started = Date.now();
const nowS = () => Math.floor(Date.now() / 1000);
const powerShell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const text = (value) => typeof value === 'string' ? value.slice(0, 2048) : '';
const finite = (value, fallback = null) => Number.isFinite(value) ? value : fallback;
const cover = (value) => typeof value === 'string' && /^https:\/\/i\.scdn\.co\/image\/[a-fA-F0-9]+$/.test(value) ? value : null;

function log(message) {
	const file = path.join(data, 'bridge.log');
	try {
		if (fs.statSync(file).size > 64 * 1024) fs.writeFileSync(file, '');
	} catch {}
	try {
		fs.appendFileSync(file, new Date().toISOString() + ' ' + message + '\n');
	} catch {}
}

function writeAtomic(target, body) {
	fs.writeFileSync(target + '.tmp', body);
	fs.renameSync(target + '.tmp', target);
}

// Windows releases a named mutex when its owning process dies. The helper holds it until
// the bridge's stdin pipe closes, including when the bridge is terminated without exit hooks.
// bridge.pid is informational only: PID reuse and leftover recovery files cannot block startup.
async function lock() {
	const file = path.join(data, 'bridge.pid');
	const key = crypto.createHash('sha256').update(fs.realpathSync(data).toLowerCase()).digest('hex');
	const script = "$ErrorActionPreference = 'Stop'; $owned = $false; "
		+ "$mutex = [System.Threading.Mutex]::new($false, 'Local\\tern-spotify-" + key + "'); "
		+ 'try { try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }; '
		+ "if (-not $owned) { exit 0 }; [Console]::Out.WriteLine('LOCKED'); [Console]::Out.Flush(); "
		+ '[Console]::In.ReadLine() | Out-Null } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }';
	const child = childProcess.spawn(powerShell, ['-NoProfile', '-NonInteractive', '-Command', script],
		{ windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
	let acquired = false;
	const held = await new Promise((resolve, reject) => {
		let output = '', errors = '';
		const timer = setTimeout(() => {
			child.kill();
			reject(new Error('Timed out acquiring the Spotify bridge mutex.'));
		}, 5000);
		child.stdout.setEncoding('utf8');
		child.stderr.setEncoding('utf8');
		child.stdout.on('data', (chunk) => {
			output += chunk;
			if (output.includes('LOCKED\n') || output.includes('LOCKED\r\n')) {
				acquired = true;
				clearTimeout(timer);
				resolve(true);
			}
		});
		child.stderr.on('data', (chunk) => { errors = (errors + chunk).slice(-4096); });
		child.on('error', (error) => { clearTimeout(timer); reject(error); });
		child.on('exit', (code) => {
			clearTimeout(timer);
			if (acquired) {
				log('Bridge mutex holder exited unexpectedly.');
				process.exit(1);
			}
			if (code === 0) resolve(false);
			else reject(new Error('Could not acquire the Spotify bridge mutex: ' + (errors.trim() || 'exit ' + code)));
		});
	});
	if (!held) return false;
	process.on('exit', () => {
		try {
			if (Number(fs.readFileSync(file, 'utf8')) === process.pid) fs.unlinkSync(file);
		} catch {}
		child.kill();
	});
	fs.writeFileSync(file, String(process.pid));
	return true;
}

// ---- Spotify app ---------------------------------------------------------------------------
let launchedAt = 0;

// Opens (or focuses) the desktop app; the Web API sees it once it registers as a device.
async function launch() {
	const env = { ...process.env };
	delete env.ELECTRON_RUN_AS_NODE;
	await new Promise((resolve, reject) => {
		const child = childProcess.spawn(appExe, [], { detached: true, stdio: 'ignore', env, windowsHide: false });
		child.once('error', reject);
		child.once('spawn', () => { child.unref(); resolve(); });
	});
	launchedAt = Date.now();
	nextPollAt = 0;
}

// ---- Authorization (PKCE) ------------------------------------------------------------------
// token.json holds { client_id, access_token, refresh_token, expires_at }; tokens are never logged.
let token = null;
let authProblem = null;
let login = null;
let refreshing = null;
let currentUserRequest = null;

function loadToken() {
	try {
		const value = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
		if (value && value.client_id === clientId && typeof value.refresh_token === 'string' && value.refresh_token) token = value;
	} catch {}
}

function forgetToken(reason) {
	token = null;
	currentUserRequest = null;
	likedStates.clear();
	state = null;
	authProblem = reason;
	try { fs.unlinkSync(TOKEN_FILE); } catch {}
}

async function tokenRequest(params, session = null, expectedToken = null) {
	const response = await fetch(ACCOUNTS + '/api/token', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({ client_id: clientId, ...params }),
		signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS), redirect: 'error',
	});
	const body = await response.json().catch(() => ({}));
	if (!response.ok) {
		const error = new Error('Spotify sign-in failed: ' + (body.error_description || body.error || 'HTTP ' + response.status));
		error.revoked = body.error === 'invalid_grant' || body.error === 'invalid_client';
		throw error;
	}
	if (typeof body.access_token !== 'string' || !body.access_token) throw new Error('Spotify sign-in returned no access token.');
	const refreshToken = typeof body.refresh_token === 'string' && body.refresh_token ? body.refresh_token : params.refresh_token;
	if (!refreshToken) throw new Error('Spotify sign-in returned no refresh token.');
	const value = {
		client_id: clientId, access_token: body.access_token, refresh_token: refreshToken,
		expires_at: Date.now() + (finite(body.expires_in, 3600)) * 1000,
	};
	if (session && login !== session) throw new Error('Spotify sign-in is no longer pending.');
	if (expectedToken && token !== expectedToken) return;
	writeAtomic(TOKEN_FILE, JSON.stringify(value));
	token = value;
	currentUserRequest = null;
	likedStates.clear();
	authProblem = null;
}

// One refresh at a time; a revoked grant signs out instead of retrying.
function refresh() {
	if (!refreshing) {
		const current = token;
		refreshing = tokenRequest({ grant_type: 'refresh_token', refresh_token: current.refresh_token }, null, current)
			.catch((error) => {
				if (error.revoked && token === current) forgetToken('Spotify sign-in expired or was revoked. Sign in again.');
				throw error;
			})
			.finally(() => { refreshing = null; });
	}
	return refreshing;
}

function openBrowser(url) {
	const child = childProcess.spawn('rundll32.exe', ['url.dll,FileProtocolHandler', url], { detached: true, stdio: 'ignore', windowsHide: true });
	child.once('error', (error) => log('browser: ' + error.message));
	child.unref();
}

function endLogin(session, problem) {
	if (login !== session) return;
	login = null;
	clearTimeout(session.timer);
	session.server.close();
	session.server.closeIdleConnections();
	authProblem = problem;
	publish();
}

function answer(res, status, message) {
	res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', Connection: 'close' });
	res.end(message + '\n');
}

async function onCallback(session, req, res) {
	const url = new URL(req.url, REDIRECT_URI);
	if (req.method !== 'GET' || url.pathname !== '/callback') return answer(res, 404, 'Not found.');
	// A stray or replayed request must not end the pending sign-in.
	if (login !== session || typeof session.state !== 'string' || url.searchParams.get('state') !== session.state) return answer(res, 400, 'This sign-in link is not the pending Tern sign-in.');
	const error = url.searchParams.get('error');
	const code = url.searchParams.get('code');
	if (error || !code) {
		const problem = 'Spotify sign-in was not completed (' + (error || 'no code') + ').';
		answer(res, 400, problem);
		return endLogin(session, problem);
	}
	session.state = null; // The code is single-use.
	try {
		await tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI, code_verifier: session.verifier }, session);
	} catch (failure) {
		answer(res, 500, failure.message);
		return endLogin(session, failure.message);
	}
	answer(res, 200, 'Signed in to Spotify. You can close this tab and return to Tern.');
	nextPollAt = 0;
	endLogin(session, null);
}

async function startLogin() {
	if (login) return;
	const verifier = crypto.randomBytes(48).toString('base64url');
	const session = {
		verifier, state: crypto.randomBytes(16).toString('hex'), timer: null,
		server: http.createServer((req, res) => {
			onCallback(session, req, res).catch((error) => { log('callback: ' + error.message); answer(res, 500, 'Sign-in failed.'); });
		}),
	};
	await new Promise((resolve, reject) => {
		session.server.once('error', (error) => reject(error.code === 'EADDRINUSE'
			? new Error('Port ' + REDIRECT_PORT + ' is in use, so Spotify sign-in cannot receive its callback.') : error));
		session.server.listen(REDIRECT_PORT, '127.0.0.1', resolve);
	});
	session.timer = setTimeout(() => endLogin(session, 'Spotify sign-in timed out. Choose Sign in to retry.'), LOGIN_TIMEOUT_MS);
	login = session;
	authProblem = null;
	const url = new URL(ACCOUNTS + '/authorize');
	url.search = new URLSearchParams({
		client_id: clientId, response_type: 'code', redirect_uri: REDIRECT_URI, scope: SCOPES,
		code_challenge_method: 'S256', code_challenge: crypto.createHash('sha256').update(verifier).digest('base64url'),
		state: session.state,
	}).toString();
	openBrowser(url.href);
}

// ---- Web API -------------------------------------------------------------------------------
let rateLimitedUntil = 0;

function apiError(status, message, reason) {
	const error = new Error(message);
	error.status = status;
	error.reason = reason;
	return error;
}

function rateLimitError() {
	return apiError(429, 'Spotify rate limit reached; retrying in ' + Math.ceil((rateLimitedUntil - Date.now()) / 1000) + ' s.');
}

async function api(method, route, { query, body, measured } = {}, retried = false) {
	if (!token) throw apiError(401, 'Sign in to Spotify first.');
	if (Date.now() < rateLimitedUntil) throw rateLimitError();
	if (Date.now() > token.expires_at - 60000) await refresh();
	const url = new URL(API + route);
	for (const [key, value] of Object.entries(query || {})) url.searchParams.set(key, String(value));
	const sent = Date.now();
	const response = await fetch(url, {
		method,
		headers: { Authorization: 'Bearer ' + token.access_token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
		// Spotify rejects bodiless PUT/POST without a Content-Length.
		body: body ? JSON.stringify(body) : method === 'GET' ? undefined : '',
		signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS), redirect: 'error',
	});
	if (response.status === 401 && !retried) {
		await refresh();
		return api(method, route, { query, body, measured }, true);
	}
	if (response.status === 429) {
		const wait = Number(response.headers.get('retry-after'));
		rateLimitedUntil = Math.max(rateLimitedUntil, Date.now() + (Number.isFinite(wait) && wait > 0 ? wait : 5) * 1000);
		throw rateLimitError();
	}
	const raw = await response.text();
	let json = null;
	try { json = raw ? JSON.parse(raw) : null; } catch {}
	if (!response.ok) {
		throw apiError(response.status, 'Spotify: ' + text(json?.error?.message || 'HTTP ' + response.status), json?.error?.reason);
	}
	if (measured) measured.at = Math.round((sent + Date.now()) / 2);
	return json;
}

function currentUserId() {
	if (currentUserRequest) return currentUserRequest;
	const request = api('GET', '/me').then((value) => {
		return currentUserRequest === request ? text(value?.id) || null : null;
	}).catch((error) => {
		log('current user: ' + error.message);
		return null;
	});
	currentUserRequest = request;
	return request;
}

// ---- Playback state ------------------------------------------------------------------------
let state = null;
let apiProblem = null;
let polling = null;
let nextPollAt = 0;

function names(list) {
	return (Array.isArray(list) ? list : []).map((artist) => text(artist?.name)).filter(Boolean);
}

// GET /me/player → the snapshot's view. `at` is when Spotify measured progress_ms; the response's
// own timestamp is the last playback change, not the measurement.
function playerState(p, at) {
	const item = p.item;
	const disallows = p.actions?.disallows || {};
	const device = p.device && typeof p.device === 'object' ? p.device : null;
	const usable = !!device && device.is_restricted !== true;
	const playing = p.is_playing === true;
	let track = null;
	if (item && typeof item.uri === 'string' && /^spotify:(track|episode):[A-Za-z0-9]+$/.test(item.uri)) {
		const episode = item.type === 'episode';
		const artists = episode ? [text(item.show?.name)].filter(Boolean) : names(item.artists);
		track = {
			id: item.uri, title: text(item.name), artist: artists.join(', '), artists,
			album: episode ? '' : text(item.album?.name), length_ms: finite(item.duration_ms), episode,
			cover: cover(((episode ? item.images || item.show?.images : item.album?.images) || [])[0]?.url),
		};
	}
	const volume = usable && device.supports_volume !== false ? finite(device.volume_percent) : null;
	return {
		track, state: playing ? 'PLAYING' : 'NOT_PLAYING',
		time_s: Math.max(0, finite(p.progress_ms, 0)) / 1000, synced_at: at,
		shuffle: p.shuffle_state === true, repeat: { context: 'all', track: 'one' }[p.repeat_state] || 'off',
		volume, muted: volume === 0,
		context: typeof p.context?.uri === 'string' ? p.context.uri : null,
		can: {
			toggle: usable && disallows[playing ? 'pausing' : 'resuming'] !== true,
			next: usable && disallows.skipping_next !== true,
			prev: usable && disallows.skipping_prev !== true,
			seek: usable && !!track && disallows.seeking !== true,
			shuffle: usable && disallows.toggling_shuffle !== true,
			repeat: usable && disallows.toggling_repeat_context !== true && disallows.toggling_repeat_track !== true,
			volume: volume !== null,
		},
	};
}

function poll() {
	if (polling || !token) return;
	polling = (async () => {
		const measured = {};
		try {
			const value = await api('GET', '/me/player', { query: { additional_types: 'episode' }, measured });
			state = value ? playerState(value, measured.at) : null;
			apiProblem = null;
			if (state) {
				if (state.track || state.can.toggle) launchedAt = 0;
				details(state);
			}
		} catch (error) {
			if (!token) apiProblem = null;
			else if (error.status !== 429 || rateLimitedUntil - Date.now() > QUIET_RATE_LIMIT_MS) apiProblem = error.message;
		} finally {
			polling = null;
			publish();
		}
	})();
}

// Context names are looked up once per change; the queue once per change and then every
// QUEUE_REFRESH_MS, so tracks queued from the Spotify app show up without a track change.
const QUEUE_MAX = 10;
const QUEUE_REFRESH_MS = 30000;
const contextNames = new Map();
let queueKey = '';
let queueItems = null;
let queueAt = 0;
let queueLoading = null;
// Library status is checked once per URI/token, and again after a successful Like command.
const likedStates = new Map();

function libraryState(uri) {
	if (!token || Date.now() < rateLimitedUntil) return;
	let entry = likedStates.get(uri);
	if (entry?.checked || entry?.request) return;
	if (!entry) {
		entry = {};
		likedStates.set(uri, entry);
	}
	const request = api('GET', '/me/library/contains', { query: { uris: uri } }).then((value) => {
		if (likedStates.get(uri) !== entry || entry.request !== request) return;
		if (!Array.isArray(value) || typeof value[0] !== 'boolean') throw new Error('Spotify returned no library status.');
		entry.value = value[0];
		entry.checked = true;
		publish();
	}).catch((error) => {
		if (likedStates.get(uri) === entry && entry.request === request
			&& error.status && error.status !== 429 && error.status < 500) {
			delete entry.value;
			entry.checked = true;
			publish();
		}
		log('library ' + uri + ': ' + error.message);
	}).finally(() => {
		if (entry.request === request) entry.request = null;
	});
	entry.request = request;
}

function contextName(uri) {
	if (contextNames.has(uri)) return contextNames.get(uri);
	if (/^spotify:user:[^:]+:collection$/.test(uri)) return 'Liked Songs';
	const match = /^spotify:(playlist|album|artist|show):([A-Za-z0-9]+)$/.exec(uri);
	if (!match) return null;
	if (Date.now() < rateLimitedUntil) return null;
	contextNames.set(uri, null);
	api('GET', '/' + match[1] + 's/' + match[2], { query: match[1] === 'playlist' ? { fields: 'name' } : {} })
		.then((value) => { contextNames.set(uri, text(value?.name) || null); publish(); })
		.catch((error) => {
			if (!error.status || error.status === 429 || error.status >= 500) contextNames.delete(uri);
			log('context ' + uri + ': ' + error.message);
		});
	return null;
}

function queueEntry(item) {
	const episode = item?.type === 'episode';
	return {
		title: text(item?.name),
		artist: episode ? text(item?.show?.name) : names(item?.artists).join(', '),
		...(finite(item?.duration_ms) ? { length_ms: item.duration_ms } : {}),
	};
}

function details(s) {
	if (s.context) contextName(s.context);
	if (!s.track) return;
	libraryState(s.track.id);
	const key = [s.track.id, s.context, s.shuffle].join('|');
	const changed = key !== queueKey;
	if (!changed && (queueLoading?.key === key || Date.now() - queueAt < QUEUE_REFRESH_MS)) return;
	if (changed) {
		queueKey = key;
		queueItems = null;
	}
	queueAt = Date.now();
	const request = { key };
	queueLoading = request;
	api('GET', '/me/player/queue').then((value) => {
		if (queueKey !== key || queueLoading !== request) return;
		queueItems = (Array.isArray(value?.queue) ? value.queue : []).slice(0, QUEUE_MAX).map(queueEntry);
		publish();
	}).catch((error) => {
		if (queueKey === key && queueLoading === request) queueAt = 0; // Retry with the next poll.
		log('queue: ' + error.message);
	}).finally(() => {
		if (queueLoading === request) queueLoading = null;
	});
}

// ---- Lyrics --------------------------------------------------------------------------------
// LRCLIB, once per track transition. Persistence retries retain the result, not the request.
let lyricsId = null;
let lyricsAbort = null;
let lyricsPending = null;

function persistLyrics() {
	if (lyricsPending === null) return;
	try {
		writeAtomic(path.join(data, 'lyrics.json'), lyricsPending);
		lyricsPending = null;
	} catch {} // Windows readers can hold the destination; the next publish retries.
}

function lyricsResult(id, value) {
	if (value === null) return { v: 1, id, status: 'none', synced: false, lines: [] };
	if (!value || typeof value !== 'object' || typeof value.synced !== 'boolean'
		|| !Array.isArray(value.lines) || value.lines.length > 512) {
		throw new Error('Lyrics returned an unsupported response.');
	}
	const lines = [];
	let previous = -1, bytes = 0;
	for (const line of value.lines) {
		if (!line || typeof line.text !== 'string' || Buffer.byteLength(line.text, 'utf8') > 2048
			|| !Number.isSafeInteger(line.t) || line.t < 0 || line.t > 86400000
			|| (value.synced && line.t < previous)) {
			throw new Error('Lyrics returned an invalid line.');
		}
		bytes += Buffer.byteLength(line.text, 'utf8');
		if (bytes > 256 * 1024) throw new Error('Lyrics exceeded the text limit.');
		previous = line.t;
		lines.push({ t: line.t, text: line.text });
	}
	return { v: 1, id, status: lines.length ? 'ok' : 'none', synced: lines.length ? value.synced : false, lines };
}

// `[mm:ss.xx]text`, possibly with several stamps per line; tags such as [ar:...] are skipped.
function parseLrc(source) {
	const lines = [];
	for (const raw of source.split(/\r?\n/)) {
		const stamps = [];
		let rest = raw, match;
		while ((match = /^\[(\d+):(\d{1,2}(?:[.:]\d{1,3})?)\]/.exec(rest))) {
			stamps.push(Math.round((Number(match[1]) * 60 + Number(match[2].replace(':', '.'))) * 1000));
			rest = rest.slice(match[0].length);
		}
		for (const t of stamps) lines.push({ t, text: rest.trim() });
	}
	return lines.sort((a, b) => a.t - b.t);
}

let lyricsRateLimitedUntil = 0;

async function lrclib(track, artist, signal) {
	if (Date.now() < lyricsRateLimitedUntil) throw new Error('LRCLIB is rate limited; lyrics are unavailable for this track.');
	const query = { track_name: track.title, artist_name: artist };
	if (track.album) query.album_name = track.album;
	const seconds = Math.round((track.length_ms || 0) / 1000);
	if (seconds >= 1 && seconds <= 3600) query.duration = seconds;
	const response = await fetch(LRCLIB + '?' + new URLSearchParams(query), {
		headers: { 'User-Agent': USER_AGENT }, signal, redirect: 'error',
	});
	if (response.status === 404) return null;
	if (response.status === 429 || response.status === 503) {
		const wait = Number(response.headers.get('retry-after'));
		lyricsRateLimitedUntil = Math.max(lyricsRateLimitedUntil, Date.now() + (Number.isFinite(wait) && wait > 0 ? wait : 5) * 1000);
	}
	if (!response.ok) throw new Error('LRCLIB lyrics request failed (HTTP ' + response.status + ').');
	return response.json();
}

// Resolves null when no lyrics exist; the joined artist list is tried before the first artist.
async function fetchLyrics(track, signal) {
	if (track.episode || !track.title || !track.artists.length) return null;
	let record = await lrclib(track, track.artist, signal);
	if (!record && track.artists.length > 1) record = await lrclib(track, track.artists[0], signal);
	if (!record || record.instrumental === true) return null;
	if (typeof record.syncedLyrics === 'string' && record.syncedLyrics.trim()) {
		const lines = parseLrc(record.syncedLyrics);
		if (lines.length) return { synced: true, lines };
	}
	if (typeof record.plainLyrics === 'string' && record.plainLyrics.trim()) {
		return { synced: false, lines: record.plainLyrics.split(/\r?\n/).map((line) => ({ t: 0, text: line.trim() })) };
	}
	return null;
}

function updateLyrics(track) {
	const id = track ? track.id : '';
	if (id !== lyricsId) {
		lyricsId = id;
		lyricsAbort?.abort();
		lyricsAbort = null;
		// Invalidate the previous file while the new track's request is pending.
		lyricsPending = JSON.stringify({ v: 1, id: '', status: 'none', synced: false, lines: [] });
		persistLyrics();
		if (track) {
			const controller = new AbortController();
			lyricsAbort = controller;
			(async () => {
				let result;
				try {
					result = lyricsResult(id, await fetchLyrics(track, AbortSignal.any([controller.signal, AbortSignal.timeout(LYRICS_TIMEOUT_MS)])));
				} catch (error) {
					if (controller.signal.aborted) return;
					result = { v: 1, id, status: 'error', synced: false, lines: [], error: String(error.message || error).slice(0, 512) };
				}
				if (lyricsAbort !== controller) return;
				lyricsAbort = null;
				lyricsPending = JSON.stringify(result);
				persistLyrics();
			})();
		}
	}
	persistLyrics();
}

// ---- Snapshot ------------------------------------------------------------------------------
let timeline = 0;
let lastSync = '';
let reply = null;
let lastBody = '';
let wroteAt = 0;

function publish() {
	const snap = { v: 1, os: process.platform, pid: process.pid, app: !!token, playing: false, timeline };
	const s = token ? state : null;
	const track = s && s.track;
	if (!token) {
		snap.login = true;
		snap.problem = login ? 'Finish signing in to Spotify in your browser.' : authProblem || 'Sign in to let Tern control Spotify.';
	} else if (apiProblem) {
		snap.problem = apiProblem;
	} else if (!track && launchedAt && Date.now() - launchedAt < LAUNCH_GRACE_MS) {
		snap.starting = true;
	}
	updateLyrics(track);
	snap.can = {};
	for (const key of ['toggle', 'next', 'prev', 'seek', 'shuffle', 'repeat', 'volume']) snap.can[key] = !!(s && s.can[key]);
	if (s) {
		const queue = track && queueKey === [track.id, s.context, s.shuffle].join('|') ? queueItems : null;
		Object.assign(snap, {
			shuffle: s.shuffle, repeat: s.repeat, volume: s.volume !== null ? Math.round(s.volume) : undefined,
			muted: s.muted, source: (s.context && contextName(s.context)) || undefined,
			queue: queue || undefined, next: queue?.[0] || undefined,
		});
	}
	if (track) {
		const sync = [track.id, s.state, s.time_s, s.synced_at].join('|');
		if (sync !== lastSync) { lastSync = sync; timeline++; }
		const playing = s.state === 'PLAYING';
		let position = s.time_s * 1000 + (playing ? Date.now() - s.synced_at : 0);
		if (track.length_ms) position = Math.min(position, track.length_ms);
		Object.assign(snap, {
			track: { id: track.id, title: track.title, artist: track.artist, album: track.album, length_ms: track.length_ms || undefined },
			playing, position_ms: Math.max(0, Math.round(position)), timeline,
		});
		if (track.cover) snap.cover = { key: track.cover, url: track.cover };
		const liked = likedStates.get(track.id)?.value;
		if (typeof liked === 'boolean') snap.liked = liked;
	} else if (lastSync) {
		lastSync = '';
		snap.timeline = ++timeline;
	}
	if (reply) snap.reply = reply;
	const body = JSON.stringify({ ...snap, position_ms: undefined });
	if (body === lastBody && Date.now() - wroteAt < HEARTBEAT_MS) return;
	snap.beat = nowS();
	try {
		writeAtomic(path.join(data, 'now.json'), JSON.stringify(snap));
		lastBody = body;
		wroteAt = Date.now();
	} catch {} // A Windows reader may hold the file; the next heartbeat retries the snapshot only.
}

// ---- Commands ------------------------------------------------------------------------------
const REPEAT = { off: 'off', all: 'context', one: 'track' };
let unmuteVolume = null;

function numberArg(arg, max) {
	const n = Number(arg);
	if (arg === '' || !Number.isFinite(n)) throw new Error('Invalid numeric playback argument');
	return Math.round(Math.max(0, Math.min(max, n)));
}

function onOff(arg, what) {
	if (arg !== 'on' && arg !== 'off') throw new Error('Invalid ' + what + ' argument');
	return arg === 'on';
}

// Without an active device Spotify answers 404; start on this computer's app when it is available.
async function play(body) {
	try {
		return await api('PUT', '/me/player/play', { body });
	} catch (error) {
		if (error.status !== 404) throw error;
		const devices = (await api('GET', '/me/player/devices'))?.devices || [];
		const usable = devices.filter((device) => device && typeof device.id === 'string' && device.is_restricted !== true);
		const device = usable.find((candidate) => candidate.type === 'Computer') || usable[0];
		if (!device) throw new Error('No Spotify device is available. Open Spotify first.');
		return api('PUT', '/me/player/play', { query: { device_id: device.id }, body });
	}
}

async function command(op, arg) {
	const s = state;
	switch (op) {
		case 'toggle': return s && s.state === 'PLAYING' ? api('PUT', '/me/player/pause') : play();
		case 'next': return api('POST', '/me/player/next');
		case 'prev': return api('POST', '/me/player/previous');
		case 'seek': return api('PUT', '/me/player/seek', { query: { position_ms: numberArg(arg, s?.track?.length_ms || 86400000) } });
		case 'shuffle': return api('PUT', '/me/player/shuffle', { query: { state: onOff(arg, 'shuffle') } });
		case 'repeat': {
			if (!Object.hasOwn(REPEAT, arg)) throw new Error('Invalid repeat mode');
			return api('PUT', '/me/player/repeat', { query: { state: REPEAT[arg] } });
		}
		case 'volume': return api('PUT', '/me/player/volume', { query: { volume_percent: numberArg(arg, 100) } });
		case 'mute': {
			// The Web API has no mute: muting remembers the volume that unmuting restores.
			if (onOff(arg, 'mute')) {
				if (s && s.volume > 0) unmuteVolume = s.volume;
				return api('PUT', '/me/player/volume', { query: { volume_percent: 0 } });
			}
			return api('PUT', '/me/player/volume', { query: { volume_percent: unmuteVolume || 50 } });
		}
		case 'play': {
			const match = /^(track|album|artist|playlist) (spotify:(track|album|artist|playlist):[A-Za-z0-9]+)$/.exec(arg);
			if (!match || match[1] !== match[3]) throw new Error('Invalid Spotify search result');
			return play(match[1] === 'track' ? { uris: [match[2]] } : { context_uri: match[2] });
		}
		case 'like': {
			const match = /^(on|off) (spotify:(track|episode):[A-Za-z0-9]+)$/.exec(arg);
			if (!match) throw new Error('Invalid Spotify Like argument');
			const liked = match[1] === 'on';
			const uri = match[2];
			try {
				await api(liked ? 'PUT' : 'DELETE', '/me/library', { query: { uris: uri } });
			} catch (error) {
				if (error.status === 403) throw new Error('Spotify denied this action. Sign in again to grant library/playlist permissions.');
				throw error;
			}
			likedStates.set(uri, { value: liked });
			publish();
			libraryState(uri);
			return;
		}
		case 'add': {
			const match = /^spotify:playlist:([A-Za-z0-9]+) (spotify:(track|episode):[A-Za-z0-9]+)$/.exec(arg);
			if (!match) throw new Error('Invalid Spotify Add to playlist argument');
			try {
				return await api('POST', '/playlists/' + match[1] + '/items', { body: { uris: [match[2]] } });
			} catch (error) {
				if (error.status === 403) throw new Error('Spotify denied this action. Sign in again to grant library/playlist permissions.');
				throw error;
			}
		}
		default: throw new Error('Unknown Spotify command: ' + op);
	}
}

let latestSearchId = null;
let latestPlaylistsId = null;

function searchItems(result, playlistUser) {
	const items = [];
	const add = (kind, list, detail) => {
		for (const item of Array.isArray(list?.items) ? list.items : []) {
			if (!item || !new RegExp('^spotify:' + kind + ':[A-Za-z0-9]+$').test(item.uri || '')) continue;
			items.push({
				kind, id: item.uri, title: text(item.name), detail: detail(item),
				...(kind === 'track' && finite(item.duration_ms) ? { length_s: item.duration_ms / 1000 } : {}),
				...(kind === 'playlist' && playlistUser !== undefined ? {
					editable: playlistUser !== null && (item.owner?.id === playlistUser || item.collaborative === true),
				} : {}),
			});
		}
	};
	add('track', result?.tracks, (item) => names(item.artists).join(', '));
	add('artist', result?.artists, () => '');
	add('album', result?.albums, (item) => names(item.artists).join(', '));
	add('playlist', result?.playlists, (item) => text(item.owner?.display_name));
	return items;
}

async function search(id, query) {
	const out = { id, query };
	try {
		if (!query.trim() || query.length > 512) throw new Error('Search requires 1–512 characters.');
		// Development-mode apps get at most 10 results per type; 5 each keeps the list short.
		out.items = searchItems(await api('GET', '/search', {
			query: { q: query, type: 'track,artist,album,playlist', limit: 5, market: 'from_token' },
		}));
	} catch (error) {
		out.error = error.message;
	}
	if (id !== latestSearchId) return;
	writeAtomic(path.join(data, 'search.json'), JSON.stringify(out));
	if (out.error) throw new Error(out.error);
}

async function playlists(id, arg) {
	const offset = Number(arg);
	const out = { id, items: [], offset };
	try {
		if (arg === '' || !Number.isSafeInteger(offset) || offset < 0) throw new Error('Playlist offset must be a nonnegative integer.');
		const result = await api('GET', '/me/playlists', { query: { limit: 20, offset } });
		out.items = searchItems({ playlists: result }, await currentUserId());
		if (result?.next) out.next = offset + 20;
	} catch (error) {
		out.error = error.status === 403 ? 'Spotify playlist access was denied. Sign in again to grant playlist permissions.' : error.message;
	}
	if (id !== latestPlaylistsId) return;
	writeAtomic(path.join(data, 'playlists.json'), JSON.stringify(out));
	if (out.error) throw new Error(out.error);
}

async function execute(id, op, arg) {
	if (op === 'login') return startLogin();
	if (op === 'launch') return launch();
	if (op === 'search') {
		latestSearchId = id;
		// Search failures always reach search.json, including a signed-out bridge.
		search(id, arg).catch((error) => log('search: ' + error.message));
		return;
	}
	if (op === 'playlists') {
		latestPlaylistsId = id;
		playlists(id, arg).catch((error) => log('playlists: ' + error.message));
		return;
	}
	try {
		await command(op, arg);
	} finally {
		if (op === 'next' || op === 'prev' || op === 'play' || op === 'shuffle') {
			queueKey = '';
			queueItems = null;
			queueAt = 0;
			queueLoading = null;
		}
		// Spotify applies commands asynchronously; look again shortly instead of trusting the reply.
		nextPollAt = Math.min(nextPollAt, Date.now() + AFTER_COMMAND_MS);
	}
}

let draining = false;
async function drainInbox() {
	if (draining) return;
	draining = true;
	try {
		let entries;
		try { entries = fs.readdirSync(INBOX).filter((name) => name.endsWith('.cmd')).sort(); }
		catch { return; }
		let lastSearch = -1;
		entries.forEach((name, index) => {
			try { if (fs.readFileSync(path.join(INBOX, name), 'utf8').startsWith('search ')) lastSearch = index; }
			catch {}
		});
		for (const [index, name] of entries.entries()) {
			const file = path.join(INBOX, name);
			let body;
			try { body = fs.readFileSync(file, 'utf8').trim(); } catch { continue; }
			const id = name.slice(0, -4);
			const stamp = Number(id.split('-')[0]);
			const stale = !stamp || nowS() - stamp > COMMAND_MAX_AGE_S;
			if (!body && !stale) continue;
			try { fs.unlinkSync(file); } catch { continue; } // Never run an undeleted command twice.
			if (stale || (body.startsWith('search ') && index < lastSearch)) continue;
			const space = body.indexOf(' ');
			const op = space < 0 ? body : body.slice(0, space);
			const arg = space < 0 ? '' : body.slice(space + 1).trim();
			reply = { id };
			try { await execute(id, op, arg); }
			catch (error) { reply.error = error.message; }
			publish();
		}
	} finally { draining = false; }
}

// ---- Main ----------------------------------------------------------------------------------
function pluginAgeS() {
	try {
		const stamp = Number(fs.readFileSync(path.join(data, 'alive'), 'utf8'));
		return Number.isFinite(stamp) && stamp > 0 ? nowS() - stamp : Infinity;
	} catch { return Infinity; }
}

// Polls on schedule, after commands, and when the extrapolated track has ended.
function schedule() {
	const s = state;
	const now = Date.now();
	if (s && s.track && s.state === 'PLAYING' && s.track.length_ms
		&& s.time_s * 1000 + now - s.synced_at > s.track.length_ms + 500 && now - s.synced_at > 1000) {
		nextPollAt = Math.min(nextPollAt, now);
	}
	if (now >= nextPollAt && !polling && token) {
		nextPollAt = now + POLL_MS;
		poll();
	}
}

async function main() {
	fs.mkdirSync(INBOX, { recursive: true });
	if (!await lock()) process.exit(0);
	loadToken();
	try { fs.watch(INBOX, () => drainInbox().catch((error) => log('inbox: ' + error.message))); } catch {}
	setInterval(() => drainInbox().catch((error) => log('inbox: ' + error.message)), 250);
	setInterval(schedule, 200);
	setInterval(() => {
		if (Date.now() - started > ORPHAN_AFTER_S * 1000 && pluginAgeS() > ORPHAN_AFTER_S) process.exit(0);
		publish();
	}, HEARTBEAT_MS);
	schedule();
	publish();
}
main().catch((error) => {
	log('startup: ' + error.message);
	console.error(error.message);
	process.exit(1);
});
process.on('uncaughtException', (error) => {
	log('uncaught: ' + (error && error.stack ? error.stack : error));
	process.exit(1);
});
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

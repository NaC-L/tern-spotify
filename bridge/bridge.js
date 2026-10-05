// Spotify Windows CEF bridge. Run with Node >=22:
//   node bridge.js <data-dir> <Spotify.exe>
// File protocol matches src/link.luau. Spotify is only started/restarted by explicit commands.
'use strict';

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');
const crypto = require('crypto');

const [data, executable] = process.argv.slice(2);
if (!data || !executable || process.platform !== 'win32' || Number(process.versions.node.split('.')[0]) < 22) {
	console.error('Usage: Node >=22 on Windows: node bridge.js <data-dir> <Spotify.exe>');
	process.exit(2);
}
const appExe = path.resolve(executable);
const INBOX = path.join(data, 'inbox');
const ORIGIN = 'https://xpui.app.spotify.com';
const ENDPOINT = 'http://127.0.0.1:9228/json/list';
const PAGE_SCRIPT = fs.readFileSync(path.join(__dirname, 'spotify-page.js'), 'utf8');
// New documents in this target can navigate away; never install into another origin.
const GUARDED_SCRIPT = 'if (window.top === window && location.origin === ' + JSON.stringify(ORIGIN) + ') {\n' + PAGE_SCRIPT + '\n}';
const COMMAND_MAX_AGE_S = 10;
const ORPHAN_AFTER_S = 30;
const HEARTBEAT_MS = 1000;
const PROCESS_CHECK_MS = 3000;
const RESPONSE_TIMEOUT_MS = 8000;
const started = Date.now();
const nowS = () => Math.floor(Date.now() / 1000);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const powerShell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');

function log(message) {
	const file = path.join(data, 'bridge.log');
	try {
		if (fs.statSync(file).size > 64 * 1024) fs.writeFileSync(file, '');
	} catch {}
	try {
		fs.appendFileSync(file, new Date().toISOString() + ' ' + message + '\n');
	} catch {}
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
		child.stdout.on('data', (text) => {
			output += text;
			if (output.includes('LOCKED\n') || output.includes('LOCKED\r\n')) {
				acquired = true;
				clearTimeout(timer);
				resolve(true);
			}
		});
		child.stderr.on('data', (text) => { errors = (errors + text).slice(-4096); });
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

// CIM's executable path, not an image-name match, defines the processes we may stop.
const quotePS = (text) => "'" + text.replace(/'/g, "''") + "'";
const processQuery = 'Get-CimInstance Win32_Process -Filter ' + quotePS('Name = ' + quotePS(path.basename(appExe)))
	+ ' | Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, '
	+ quotePS(appExe) + ', [System.StringComparison]::OrdinalIgnoreCase) }';

function runPowerShell(script) {
	return new Promise((resolve, reject) => {
		childProcess.execFile(powerShell, ['-NoProfile', '-NonInteractive', '-Command', "$ErrorActionPreference = 'Stop'; " + script],
			{ windowsHide: true, encoding: 'utf8', timeout: 5000 }, (error, stdout, stderr) => {
				if (error) reject(new Error((stderr || error.message).trim()));
				else resolve(stdout.trim());
			});
	});
}

let appRunning = false;
let processCheckedAt = 0;
let processCheck = null;
let processProblem = null;
let launchedAt = 0;
let relaunching = false;

async function checkApp(force) {
	if (processCheck) return processCheck;
	if (!force && Date.now() - processCheckedAt < PROCESS_CHECK_MS) return appRunning;
	processCheck = (async () => {
		try {
			const out = await runPowerShell(processQuery + ' | Select-Object -ExpandProperty ProcessId');
			appRunning = out.split(/\r?\n/).some((line) => Number(line) > 0);
			processProblem = null;
			return appRunning;
		} catch (error) {
			processProblem = 'Could not inspect Spotify processes: ' + error.message;
			throw new Error(processProblem);
		} finally {
			processCheckedAt = Date.now();
			processCheck = null;
		}
	})();
	return processCheck;
}

async function launch() {
	const env = { ...process.env };
	delete env.ELECTRON_RUN_AS_NODE;
	await new Promise((resolve, reject) => {
		const child = childProcess.spawn(appExe, ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9228'],
			{ detached: true, stdio: 'ignore', env, windowsHide: false });
		child.once('error', reject);
		child.once('spawn', () => { child.unref(); resolve(); });
	});
	launchedAt = Date.now();
	processCheckedAt = 0;
}

async function relaunch() {
	relaunching = true;
	publish();
	try {
		await runPowerShell(processQuery + ' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }');
		const deadline = Date.now() + 5000;
		while (await checkApp(true)) {
			if (Date.now() >= deadline) throw new Error('Spotify did not stop; no new instance was launched.');
			await sleep(100);
		}
		if (ws) disconnect(ws, new Error('Spotify was explicitly restarted'));
		await launch();
	} finally {
		relaunching = false;
	}
}

// ---- DevTools ------------------------------------------------------------------------------
let ws = null;
let nextId = 0;
let connecting = false;
let connectedAt = 0;
let connectionProblem = null;
let mainFrameId = null;
let executionContextId = null;
const pending = new Map();

function disconnect(socket, error) {
	if (ws === socket) {
		ws = null;
		state = null;
		executionContextId = null;
		for (const entry of pending.values()) {
			clearTimeout(entry.timer);
			entry.reject(error);
		}
		pending.clear();
		publish();
	}
	try { socket.close(); } catch {}
}

function send(method, params = {}) {
	if (!ws || ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error('Not connected to Spotify'));
	const socket = ws;
	const id = ++nextId;
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			if (!pending.has(id)) return;
			const error = new Error('Spotify did not answer in time; the command was not retried.');
			connectionProblem = error.message;
			disconnect(socket, error);
		}, RESPONSE_TIMEOUT_MS);
		pending.set(id, { resolve, reject, timer });
		try {
			socket.send(JSON.stringify({ id, method, params }));
		} catch (error) {
			clearTimeout(timer);
			pending.delete(id);
			reject(error);
		}
	});
}

function errorText(details) {
	const ex = details.exception;
	return String(ex && ex.description ? ex.description.split('\n')[0] : details.text || 'Spotify page evaluation failed').replace(/^Error: /, '');
}

async function evaluate(expression) {
	if (executionContextId === null) throw new Error('Spotify main page context is unavailable.');
	const result = await send('Runtime.evaluate', {
		expression, contextId: executionContextId, returnByValue: true, awaitPromise: true,
	});
	if (result.exceptionDetails) throw new Error(errorText(result.exceptionDetails));
	return result.result && result.result.value;
}

function pageExpression(expression) {
	return '(() => { if (location.origin !== ' + JSON.stringify(ORIGIN)
		+ ') throw new Error("The debug target is no longer Spotify"); return ' + expression + '; })()';
}

async function install() {
	await evaluate(GUARDED_SCRIPT);
}

function spotifyTarget(target) {
	try {
		const url = new URL(target.url);
		return target.type === 'page' && url.origin === ORIGIN && !url.username && !url.password;
	} catch { return false; }
}

function debuggerURL(value) {
	const url = new URL(value);
	if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' || url.port !== '9228'
		|| url.username || url.password || url.search || url.hash || !/^\/devtools\/page\/[A-Za-z0-9_-]+$/.test(url.pathname)) {
		throw new Error('Spotify advertised an unsafe debugger URL; no script was injected.');
	}
	return url.href;
}

async function connect() {
	if (connecting || ws || relaunching) return;
	connecting = true;
	let socket;
	try {
		const response = await fetch(ENDPOINT, { signal: AbortSignal.timeout(2000), redirect: 'error' });
		if (!response.ok) throw new Error('Spotify debug endpoint returned HTTP ' + response.status);
		const targets = await response.json();
		if (!Array.isArray(targets)) throw new Error('Port 9228 is not a Spotify debugger.');
		const page = targets.find(spotifyTarget);
		if (!page) throw new Error('Port 9228 has no Spotify desktop page; no script was injected.');
		socket = new WebSocket(debuggerURL(page.webSocketDebuggerUrl));
		await new Promise((resolve, reject) => {
			const timer = setTimeout(() => finish(new Error('Spotify debugger connection timed out')), 3000);
			function finish(error) {
				clearTimeout(timer);
				socket.onopen = socket.onerror = socket.onclose = null;
				if (error) reject(error); else resolve();
			}
			socket.onopen = () => finish();
			socket.onerror = () => finish(new Error('Spotify debugger connection failed'));
			socket.onclose = () => finish(new Error('Spotify debugger closed before connecting'));
		});
		ws = socket;
		socket.onmessage = (event) => {
			if (ws !== socket) return;
			try { onMessage(JSON.parse(event.data)); }
			catch (error) { log('bad debugger message: ' + error.message); }
		};
		socket.onclose = () => disconnect(socket, new Error('Spotify debugger closed'));
		socket.onerror = () => disconnect(socket, new Error('Spotify debugger connection failed'));
		mainFrameId = (await send('Page.getFrameTree')).frameTree.frame.id;
		await send('Runtime.enable');
		// Check the connected page before installing bindings/scripts, not just discovery metadata.
		if (await evaluate('location.origin') !== ORIGIN) throw new Error('Debugger target is not Spotify; no script was injected.');
		await send('Runtime.addBinding', { name: '__ternSpotify' });
		await send('Page.addScriptToEvaluateOnNewDocument', { source: GUARDED_SCRIPT });
		await install();
		connectedAt = Date.now();
		connectionProblem = null;
		appRunning = true;
	} catch (error) {
		connectionProblem = error.message;
		if (socket) disconnect(socket, error);
	} finally {
		connecting = false;
	}
}

function onMessage(message) {
	if (message.id && pending.has(message.id)) {
		const entry = pending.get(message.id);
		pending.delete(message.id);
		clearTimeout(entry.timer);
		if (message.error) entry.reject(new Error(message.error.message));
		else entry.resolve(message.result);
		return;
	}
	if (message.method === 'Runtime.executionContextCreated') {
		const context = message.params.context;
		if (context.auxData?.isDefault && context.auxData.frameId === mainFrameId && context.origin === ORIGIN) {
			executionContextId = context.id;
		}
		return;
	}
	if (message.method === 'Runtime.executionContextsCleared'
		|| (message.method === 'Runtime.executionContextDestroyed' && message.params.executionContextId === executionContextId)) {
		executionContextId = null;
		state = null;
		publish();
		return;
	}
	if (message.method === 'Runtime.bindingCalled' && message.params.name === '__ternSpotify'
		&& executionContextId !== null && message.params.executionContextId === executionContextId) {
		state = bindingState(message.params.payload);
		publish();
	}
}

function bindingState(payload) {
	const s = JSON.parse(payload);
	if (!s || typeof s !== 'object' || Array.isArray(s)) throw new Error('Invalid Spotify state');
	const text = (value) => typeof value === 'string' ? value.slice(0, 2048) : '';
	const finite = (value, fallback = null) => Number.isFinite(value) ? value : fallback;
	const cover = (value) => typeof value === 'string' && /^https:\/\/i\.scdn\.co\/image\/[a-fA-F0-9]+$/.test(value) ? value : null;
	const track = s.track && typeof s.track === 'object' && !Array.isArray(s.track) ? {
		id: text(s.track.id), title: text(s.track.title), artist: text(s.track.artist), album: text(s.track.album),
		length_ms: finite(s.track.length_ms), cover: cover(s.track.cover),
	} : null;
	const can = {};
	for (const key of ['toggle', 'next', 'prev', 'seek', 'shuffle', 'repeat', 'volume']) can[key] = s.can?.[key] === true;
	return {
		track, can, state: s.state === 'PLAYING' ? 'PLAYING' : 'NOT_PLAYING',
		time_s: Math.max(0, finite(s.time_s, 0)), synced_at: Math.max(0, finite(s.synced_at, 0)),
		shuffle: s.shuffle === true, repeat: ['off', 'all', 'one'].includes(s.repeat) ? s.repeat : 'off',
		volume: finite(s.volume), muted: s.muted === true, quality: text(s.quality), format: text(s.format),
		source: text(s.source), problem: text(s.problem),
		next: s.next && typeof s.next === 'object' ? { title: text(s.next.title), artist: text(s.next.artist) } : null,
	};
}

// ---- Snapshot ------------------------------------------------------------------------------
let state = null;
let timeline = 0;
let lastSync = '';
let reply = null;
let lastBody = '';
let wroteAt = 0;

function publish() {
	const connected = !!(ws && ws.readyState === WebSocket.OPEN);
	const snap = { v: 1, os: process.platform, pid: process.pid, app: connected || appRunning, playing: false, timeline };
	if (relaunching || (!connected && launchedAt && Date.now() - launchedAt < 20000)) {
		snap.starting = true;
		snap.app = true;
	} else if (!connected && appRunning) {
		snap.problem = 'Spotify is running without remote control. Choose Restart Spotify to enable it.';
		if (connectionProblem) snap.problem += '\n' + connectionProblem;
		snap.relaunch = true;
	} else if (!connected && processProblem) {
		snap.problem = processProblem;
	}
	const s = connected ? state : null;
	const track = s && s.track;
	snap.can = {};
	for (const key of ['toggle', 'next', 'prev', 'seek', 'shuffle', 'repeat', 'volume']) {
		snap.can[key] = !!(s && s.can && s.can[key] === true);
	}
	if (s) {
		Object.assign(snap, {
			shuffle: s.shuffle, repeat: s.repeat, volume: Number.isFinite(s.volume) ? Math.round(s.volume) : undefined,
			muted: s.muted, quality: s.quality || undefined, format: s.format || undefined,
			source: s.source || undefined, next: s.next || undefined,
		});
	}
	if (track) {
		const sync = [track.id, s.state, s.time_s, s.synced_at].join('|');
		if (sync !== lastSync) { lastSync = sync; timeline++; }
		const playing = s.state === 'PLAYING';
		let position = Number(s.time_s || 0) * 1000 + (playing && s.synced_at ? Date.now() - s.synced_at : 0);
		if (track.length_ms) position = Math.min(position, track.length_ms);
		Object.assign(snap, {
			track: { title: track.title, artist: track.artist, album: track.album, length_ms: track.length_ms || undefined },
			playing, position_ms: Math.max(0, Math.round(position)), timeline,
		});
		if (track.cover) snap.cover = { key: track.cover, url: track.cover };
	} else if (lastSync) {
		lastSync = '';
		snap.timeline = ++timeline;
	}
	if (connected && !s) snap.problem = 'Spotify player is still loading.';
	if (s && s.problem) snap.problem = s.problem;
	if (reply) snap.reply = reply;
	const body = JSON.stringify({ ...snap, position_ms: undefined });
	if (body === lastBody && Date.now() - wroteAt < HEARTBEAT_MS) return;
	snap.beat = nowS();
	const target = path.join(data, 'now.json');
	try {
		fs.writeFileSync(target + '.tmp', JSON.stringify(snap));
		fs.renameSync(target + '.tmp', target);
		lastBody = body;
		wroteAt = Date.now();
	} catch {} // A Windows reader may hold the file; the next heartbeat retries the snapshot only.
}

// ---- Commands ------------------------------------------------------------------------------
async function command(op, arg) {
	await evaluate(pageExpression('window.__ternSpotifyCommand(' + JSON.stringify(op) + ', ' + JSON.stringify(arg) + ')'));
}

let latestSearchId = null;

async function search(id, query) {
	const out = { id, query };
	try {
		out.items = await evaluate(pageExpression('window.__ternSpotifySearch(' + JSON.stringify(query) + ')'));
	} catch (error) {
		out.error = error.message;
	}
	if (id !== latestSearchId) return;
	const target = path.join(data, 'search.json');
	fs.writeFileSync(target + '.tmp', JSON.stringify(out));
	fs.renameSync(target + '.tmp', target);
	if (out.error) throw new Error(out.error);
}

async function execute(id, op, arg) {
	if (op === 'launch') {
		if (ws) return;
		if (await checkApp(true)) throw new Error('Spotify is already running without remote control. Choose Restart Spotify explicitly.');
		return launch();
	}
	if (op === 'relaunch') return relaunch();
	if (op === 'search') {
		latestSearchId = id;
		// Search failures always reach search.json, including a disconnected player.
		search(id, arg).catch((error) => log('search: ' + error.message));
		return;
	}
	if (!ws) throw new Error(await checkApp(true) ? 'Spotify needs an explicit restart to enable remote control.' : 'Spotify is not running.');
	return command(op, arg);
}

let draining = false;
async function drainInbox() {
	if (draining) return;
	draining = true;
	try {
		let names;
		try { names = fs.readdirSync(INBOX).filter((name) => name.endsWith('.cmd')).sort(); }
		catch { return; }
		let lastSearch = -1;
		names.forEach((name, index) => {
			try { if (fs.readFileSync(path.join(INBOX, name), 'utf8').startsWith('search ')) lastSearch = index; }
			catch {}
		});
		for (const [index, name] of names.entries()) {
			const file = path.join(INBOX, name);
			let text;
			try { text = fs.readFileSync(file, 'utf8').trim(); } catch { continue; }
			const id = name.slice(0, -4);
			const stamp = Number(id.split('-')[0]);
			const stale = !stamp || nowS() - stamp > COMMAND_MAX_AGE_S;
			if (!text && !stale) continue;
			try { fs.unlinkSync(file); } catch { continue; } // Never run an undeleted command twice.
			if (stale || (text.startsWith('search ') && index < lastSearch)) continue;
			const space = text.indexOf(' ');
			const op = space < 0 ? text : text.slice(0, space);
			const arg = space < 0 ? '' : text.slice(space + 1).trim();
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

let stopping = false;
async function stop() {
	if (stopping) return;
	stopping = true;
	try {
		if (ws && executionContextId !== null) await evaluate(pageExpression('window.__ternSpotifyDispose?.()'));
	} catch (error) { log('page disposal: ' + error.message); }
	process.exit(0);
}

async function main() {
	fs.mkdirSync(INBOX, { recursive: true });
	if (!await lock()) process.exit(0);
	try { fs.watch(INBOX, () => drainInbox().catch((error) => log('inbox: ' + error.message))); } catch {}
	setInterval(() => drainInbox().catch((error) => log('inbox: ' + error.message)), 250);
	setInterval(() => {
		if (Date.now() - started > ORPHAN_AFTER_S * 1000 && pluginAgeS() > ORPHAN_AFTER_S) {
			stop();
			return;
		}
		if (!ws && !relaunching) {
			checkApp(false).then(publish).catch(() => publish());
			connect().then(publish);
		} else if (ws && !state && Date.now() - connectedAt > 3000) {
			connectedAt = Date.now();
			send('Runtime.addBinding', { name: '__ternSpotify' }).then(install).catch((error) => {
				connectionProblem = error.message;
				if (ws) disconnect(ws, error);
			});
		}
		publish();
	}, HEARTBEAT_MS);
	checkApp(true).then(publish).catch(() => publish());
	connect().then(publish);
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

// Evaluated only in Spotify's xpui page. Credentials and authenticated requests stay here.
(() => {
  'use strict';
  const VERSION = 1;
  if (window.__ternSpotifyVersion === VERSION) {
    window.__ternSpotifyEmit();
    return 'installed';
  }
  window.__ternSpotifyDispose?.();
  let player = null, connect = null, platform = null, last = '', searchDocument = null;
  let timer = null;
  const REPEAT = ['off', 'all', 'one'];

  function registryService(registry, name) {
    if (!(registry?._map instanceof Map) || typeof registry.resolve !== 'function') return null;
    const key = [...registry._map.keys()].find(k => String(k) === `Symbol(${name})`);
    return key ? registry.resolve(key) : null;
  }

  function attach() {
    const element = document.querySelector('[data-testid="now-playing-widget"]') || document.body;
    if (!element) return;
    const key = Object.keys(element).find(k => k.startsWith('__reactFiber'));
    for (let fiber = key && element[key]; fiber; fiber = fiber.return) {
      const values = [fiber.memoizedProps?.value];
      for (let context = fiber.dependencies?.firstContext; context; context = context.next) {
        values.push(context.memoizedValue);
      }
      for (const value of values) {
        if (typeof value?.getRegistry !== 'function' || typeof value.getGraphQLLoader !== 'function') continue;
        const registry = value.getRegistry();
        const candidate = registryService(registry, 'PlayerAPI');
        if (typeof candidate?.getState !== 'function') continue;
        platform = value;
        player = candidate;
        connect = registryService(registry, 'ConnectAPI');
        return;
      }
    }
  }

  function volumeInput() {
    const input = document.querySelector('[data-testid="volume-bar"] input[type="range"]');
    if (!input || input.disabled) return null;
    const key = Object.keys(input).find(k => k.startsWith('__reactProps'));
    const props = key && input[key];
    return typeof props?.onChange === 'function' ? { input, props } : null;
  }

  function coverUrl(url) {
    if (!url) return null;
    if (/^spotify:image:[a-f0-9]+$/i.test(url)) return 'https://i.scdn.co/image/' + url.split(':')[2];
    try { const u = new URL(url); return u.protocol === 'https:' && u.hostname === 'i.scdn.co' ? u.href : null; }
    catch { return null; }
  }

  function snapshot() {
    const s = player?.getState();
    const item = s?.item;
    const restrictions = s?.restrictions || {};
    const activeDevice = connect?.getState()?.activeDevice;
    const input = volumeInput();
    const volume = Number.isFinite(activeDevice?.volume) ? activeDevice.volume * 100 : null;
    const next = s?.nextItems?.[0];
    return {
      track: item ? {
        id: item.uri,
        title: item.name || '',
        artist: (item.artists || []).map(a => a.name).join(', '),
        album: item.album?.name || '',
        length_ms: s.duration || item.duration?.milliseconds || null,
        cover: coverUrl((item.album?.images || item.images || [])[0]?.url),
      } : null,
      state: s && !s.isPaused && !s.isBuffering ? 'PLAYING' : 'NOT_PLAYING',
      time_s: Number(s?.positionAsOfTimestamp || 0) / 1000,
      synced_at: Number(s?.timestamp || 0),
      shuffle: !!s?.shuffle,
      repeat: REPEAT[s?.repeat] || 'off',
      volume,
      muted: volume === 0,
      source: s?.context?.metadata?.context_description || null,
      next: next ? { title: next.name || '', artist: (next.artists || []).map(a => a.name).join(', ') } : null,
      can: {
        toggle: !!(restrictions.canPause || restrictions.canResume),
        next: restrictions.canSkipNext === true,
        prev: restrictions.canSkipPrevious === true,
        seek: restrictions.canSeek === true,
        shuffle: restrictions.canToggleShuffle === true,
        repeat: restrictions.canToggleRepeatContext === true && restrictions.canToggleRepeatTrack === true,
        volume: !!input && player?.getCapabilities?.().canChangeVolume === true,
      },
    };
  }

  function emit() {
    if (!player) attach();
    if (typeof window.__ternSpotify !== 'function') return;
    const text = JSON.stringify(snapshot());
    if (text !== last) { last = text; window.__ternSpotify(text); }
  }

  function requireCapability(op) {
    if (!player?.getState()) throw new Error('Spotify is still loading. Open a track in Spotify.');
    const can = snapshot().can;
    const capability = op === 'mute' ? 'volume' : op;
    if (capability in can && !can[capability]) throw new Error(`Spotify does not allow ${op} in the current playback context.`);
  }

  function numberArg(arg, max) {
    const n = Number(arg);
    if (!Number.isFinite(n)) throw new Error('Invalid numeric playback argument');
    return Math.max(0, Math.min(max, n));
  }

  window.__ternSpotifyCommand = async (op, arg) => {
    requireCapability(op);
    switch (op) {
      case 'toggle': await (player.getState().isPaused ? player.resume() : player.pause()); break;
      case 'next': await player.skipToNext(); break;
      case 'prev': await player.skipToPrevious(); break;
      case 'seek': await player.seekTo(numberArg(arg, player.getState().duration || Infinity)); break;
      case 'shuffle':
        if (arg !== 'on' && arg !== 'off') throw new Error('Invalid shuffle argument');
        await player.setShuffle(arg === 'on'); break;
      case 'repeat': {
        const mode = REPEAT.indexOf(arg);
        if (mode < 0) throw new Error('Invalid repeat mode');
        await player.setRepeat(mode); break;
      }
      case 'volume': {
        const slider = volumeInput();
        if (!slider) throw new Error('Spotify volume control is unavailable.');
        const value = numberArg(arg, 100) / 100 * Number(slider.input.max || 1);
        slider.props.onChange({ target: { value: String(value) } });
        break;
      }
      case 'mute': {
        if (arg !== 'on' && arg !== 'off') throw new Error('Invalid mute argument');
        const s = snapshot();
        if (s.muted !== (arg === 'on')) {
          const button = document.querySelector('[data-testid="volume-bar-toggle-mute-button"]');
          if (!button || button.disabled) throw new Error('Spotify mute control is unavailable.');
          button.click();
        }
        break;
      }
      case 'play': {
        const match = /^(track|album|artist|playlist) (spotify:(track|album|artist|playlist):[A-Za-z0-9]+)$/.exec(arg);
        if (!match || match[1] !== match[3]) throw new Error('Invalid Spotify search result');
        await player.play({ uri: match[2] }, { featureIdentifier: 'search', featureVersion: '1' }, {});
        break;
      }
      default: throw new Error('Unknown Spotify command: ' + op);
    }
    last = '';
    emit();
    return 'ok';
  };

  function findSearchDocument() {
    if (searchDocument) return searchDocument;
    // Discover the current app's query hash instead of pinning an obsolete persisted query.
    for (const module of Object.values(window.__webpack_modules__ || {})) {
      const match = /"searchModalResults","query","([a-f0-9]{64})"/.exec(String(module));
      if (match) {
        searchDocument = { name: 'searchModalResults', operation: 'query', sha256Hash: match[1], value: null };
        return searchDocument;
      }
    }
    throw new Error('Spotify search is not loaded. Open Spotify search once, then retry.');
  }

  window.__ternSpotifySearch = async query => {
    if (!platform) throw new Error('Spotify is still loading.');
    if (typeof query !== 'string' || !query.trim() || query.length > 512) throw new Error('Search requires 1–512 characters.');
    const result = await platform.getGraphQLLoader()(findSearchDocument(), {
      limit: 20, numberOfTopResults: 20, offset: 0, searchTerm: query, includeAuthors: false,
    });
    if (result.errors?.length) throw new Error(result.errors[0].message || 'Spotify search failed.');
    const items = result.data?.searchV2?.topResultsV2?.itemsV2;
    if (!Array.isArray(items)) throw new Error('Spotify search returned an unsupported response.');
    return items.flatMap(entry => {
      const item = entry.item?.data;
      if (!item) return [];
      const kind = { Track: 'track', Album: 'album', Artist: 'artist', Playlist: 'playlist' }[item.__typename];
      if (!kind || !new RegExp('^spotify:' + kind + ':[A-Za-z0-9]+$').test(item.uri || '')) return [];
      const detail = kind === 'playlist' ? (item.ownerV2?.data?.name || item.owner?.name || '')
        : (item.artists?.items || []).map(a => a.profile?.name || a.name || '').filter(Boolean).join(', ');
      return [{ kind, id: item.uri, title: item.name || item.profile?.name || '', detail,
        ...(item.duration?.totalMilliseconds ? { length_s: item.duration.totalMilliseconds / 1000 } : {}) }];
    });
  };

  window.__ternSpotifyEmit = () => { last = ''; emit(); };
  window.__ternSpotifyDispose = () => { clearInterval(timer); delete window.__ternSpotifyVersion; };
  window.__ternSpotifyVersion = VERSION;
  emit();
  timer = setInterval(() => { try { emit(); } catch { /* Document teardown: next bridge install reattaches. */ } }, 250);
  return 'installed';
})();

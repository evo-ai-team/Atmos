import { createHash } from 'node:crypto';

const intervalMs = 30 * 60 * 1000;
const sources = [
  { id: 'weather', label: 'National Weather Service · hourly forecast', url: 'https://api.weather.gov/gridpoints/MTR/86,106/forecast/hourly' },
  { id: 'event', label: 'Luma · Personal Agents Hackathon', url: 'https://luma.com/personalagenthack' },
  { id: 'menu', label: 'Proper Food · San Francisco menu PDF', url: 'https://properfood.com/wp-content/uploads/2015/05/San-Francisco_Menu.pdf' },
];
const targetHours = [2, 3, 4];
const targetInstants = targetHours.map(hour => Date.parse(`2026-11-21T0${hour}:00:00-08:00`));

function readWeather(text) {
  const periods = JSON.parse(text)?.properties?.periods;
  if (!Array.isArray(periods) || !periods.length) throw new Error('Missing hourly forecast');
  const matches = targetInstants.map(target => periods.find(p => Date.parse(p.startTime) === target));
  if (matches.some(p => !p)) return { state: 'outside-window' };
  const probabilities = matches.map(p => p.probabilityOfPrecipitation?.value);
  if (probabilities.some(n => !Number.isFinite(n) || n < 0 || n > 100)) throw new Error('Missing rain probability');
  return { state: 'ok', facts: { probabilities } };
}

function readEvent(html) {
  // Use the organizer's machine-readable event. Marketing copy, ticket count,
  // dynamic scripts and page generation timestamps are unrelated to its schedule.
  const blocks = html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi);
  for (const [, attributes, body] of blocks) {
    if (!/(?:^|\s)type\s*=\s*["']application\/ld\+json["']/i.test(attributes)) continue;
    let data;
    try { data = JSON.parse(body); } catch { continue; }
    const nodes = (Array.isArray(data) ? data : [data]).flatMap(node =>
      Array.isArray(node?.['@graph']) ? node['@graph'] : [node]);
    for (const node of nodes) {
      const types = [node?.['@type']].flat();
      if (!types.includes('Event') || node?.name?.trim?.().toLowerCase() !== 'personal agents hackathon') continue;
      const start = datedInstant(node.startDate);
      if (!start) continue;
      const facts = { start };
      const end = datedInstant(node.endDate);
      if (end) facts.end = end;
      const status = /^(?:https?:\/\/schema\.org\/)?Event(Scheduled|Cancelled|Postponed|Rescheduled|MovedOnline)$/.exec(node.eventStatus);
      if (status) facts.eventStatus = status[1];
      return { state: 'ok', facts };
    }
  }
  return { state: 'link-only' };
}

function datedInstant(value) {
  // Untimed dates and local timestamps without offsets do not establish an instant.
  if (typeof value !== 'string' || !/(Z|[+-]\d{2}:\d{2})$/i.test(value)) return undefined;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : undefined;
}

async function observe(source, fetchImpl, signal) {
  const response = await fetchImpl(source.url, {
    signal, redirect: 'error',
    headers: { 'User-Agent': 'Atmos/1.0 (local San Francisco itinerary demo)' },
  });
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    throw new Error('Source unavailable');
  }
  const type = (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
  const limit = 3 * 1024 * 1024;
  if (Number(response.headers.get('content-length')) > limit) {
    await response.body.cancel();
    throw new Error('Document too large');
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body) {
    length += chunk.length;
    if (length > limit) throw new Error('Document too large');
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (source.id === 'weather' && ['application/geo+json', 'application/json', 'application/ld+json'].includes(type))
    return readWeather(bytes.toString('utf8'));
  if (source.id === 'event' && type === 'text/html') return readEvent(bytes.toString('utf8'));
  if (source.id === 'menu' && type === 'application/pdf' && bytes.subarray(0, 5).toString() === '%PDF-') {
    return { state: 'ok', facts: { sha256: createHash('sha256').update(bytes).digest('hex') } };
  }
  throw new Error('Unexpected source format');
}

const statusText = {
  'outside-window': 'The feed omits one or more replay hours',
  'link-only': 'Page reachable · structured event details unavailable',
  unavailable: 'Refresh unavailable',
};
const goodStatus = {
  weather: 'Replay forecast verified',
  event: 'Organizer schedule verified',
  menu: 'Menu document verified',
};

export function createObserver(db, { enabled = false, fetchImpl = globalThis.fetch, clock = Date.now } = {}) {
  db.exec(`CREATE TABLE IF NOT EXISTS source_observations (
    id TEXT PRIMARY KEY, state TEXT NOT NULL, checked_at TEXT NOT NULL,
    changed_at TEXT, last_good_at TEXT, facts TEXT
  )`);
  const get = db.prepare('SELECT * FROM source_observations WHERE id = ?');
  const touch = db.prepare('UPDATE source_observations SET checked_at = ? WHERE id = ?');
  const save = db.prepare(`INSERT INTO source_observations (id,state,checked_at,changed_at,last_good_at,facts)
    VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
    state=excluded.state,checked_at=excluded.checked_at,changed_at=excluded.changed_at,
    last_good_at=excluded.last_good_at,facts=excluded.facts`);
  let lifetime;
  let storageFailed = false;

  function record(id, result) {
    const prior = get.get(id);
    const now = new Date(clock()).toISOString();
    const facts = result.facts ? JSON.stringify(result.facts) : prior?.facts ?? null;
    if (prior && result.state === prior.state && facts === prior.facts) {
      touch.run(now, id);
      return;
    }
    const changedAt = facts !== (prior?.facts ?? null) ? now : prior?.changed_at ?? null;
    // Successful checks read their confirmation time from checked_at. Freeze it
    // before recording a failure so a retry cannot make old evidence look fresh.
    const lastGoodAt = result.state === 'ok' ? null :
      prior?.state === 'ok' ? prior.checked_at : prior?.last_good_at ?? null;
    save.run(id, result.state, now, changedAt, lastGoodAt, facts);
  }

  function start() {
    if (!enabled) return Promise.resolve();
    if (lifetime) return lifetime.pending ?? Promise.resolve();
    const run = { controller: new AbortController(), pending: null };
    lifetime = run;
    const check = () => {
      if (run.pending) return run.pending;
      run.pending = Promise.resolve().then(async () => {
        if (run.controller.signal.aborted) return;
        const results = await Promise.all(sources.map(async source => {
          const signal = AbortSignal.any([run.controller.signal, AbortSignal.timeout(12000)]);
          try { return await observe(source, fetchImpl, signal); }
          catch { return { state: 'unavailable' }; }
        }));
        if (run.controller.signal.aborted) return;
        sources.forEach((source, i) => record(source.id, results[i]));
        storageFailed = false;
      }).catch(() => { storageFailed = true; }).finally(() => { run.pending = null; });
      return run.pending;
    };
    run.timer = setInterval(check, intervalMs);
    run.timer.unref();
    return check();
  }

  async function stop() {
    const run = lifetime;
    if (!run) return;
    lifetime = undefined;
    clearInterval(run.timer);
    run.controller.abort();
    await run.pending;
  }

  function snapshot() {
    let weather;
    const records = sources.map(({ id, label, url }) => {
      const row = get.get(id);
      const state = row?.state;
      const facts = row?.facts ? JSON.parse(row.facts) : undefined;
      const status = state === 'ok' ? goodStatus[id] : statusText[state] ?? 'Awaiting first check';
      if (id === 'weather' && facts) {
        const prefix = state === 'ok' ? 'NWS forecast' : 'Last verified NWS forecast';
        const values = facts.probabilities.map((percent, i) => `${targetHours[i]} AM ${percent}%`);
        weather = `${prefix} for Saturday, Nov 21, 2026, San Francisco. Chance of precipitation (PST): ${values.join(', ')}.`;
      }
      return {
        id, label, url, status, checkedAt: row?.checked_at ?? null, changedAt: row?.changed_at ?? null,
        lastGoodAt: state === 'ok' ? row.checked_at : row?.last_good_at ?? null,
        ...(facts ? { facts } : {}),
      };
    });
    let status = 'Automatic source checks are off';
    if (storageFailed) status = 'Source history could not be saved';
    else if (lifetime?.pending) status = 'Checking sources';
    else if (lifetime) status = 'Checking every 30 minutes';
    return { status, ...(weather ? { weather } : {}), sources: records };
  }
  return { start, stop, snapshot };
}

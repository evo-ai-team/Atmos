import { createHash, randomUUID } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
const uuid = /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i;
const sections = ['transit', 'breakfast', 'lunch', 'dinner', 'nightlife', 'weekend'];
const choiceSlots = sections.filter(section => section !== 'weekend');

function configuration(env) {
  if (!env.ATMOS_TEST_COGNEE_URL || !env.ATMOS_TEST_COGNEE_KEY) return null;
  const url = new URL(env.ATMOS_TEST_COGNEE_URL);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || url.search || url.hash ||
      !['/', '/api/v1', '/api/v1/'].includes(url.pathname) ||
      !/^(?!api\.|your-tenant\.)[a-z0-9-]+\.(aws|gcp)\.cognee\.ai$/.test(url.hostname)) {
    throw new Error('Use the HTTPS workspace URL from the Cognee test tenant’s API Keys page.');
  }
  return { origin: url.origin, key: env.ATMOS_TEST_COGNEE_KEY };
}

function sharedSnapshot(catalog) {
  const entries = [catalog.event, ...sections.flatMap(key => catalog[key] ?? [])];
  const facts = entries.filter(item => item?.title && item.sources?.length).map(item => {
    const lines = [item.title, item.address, item.time, item.notes, item.diet];
    if (typeof item.price === 'number') lines.push(`Planning estimate: USD ${item.price}.`);
    for (const {label, url} of item.sources) lines.push(label + ' — ' + url);
    return lines.filter(Boolean).join('\n');
  });
  return [`San Francisco reference guide, ${catalog.date}.`, ...facts].join('\n\n');
}

function visitorSnapshot(state, catalog) {
  // Only controlled fixture choices and numbers cross the network. The briefing,
  // home, work context, social contacts, expenses and draft messages stay local.
  const preferences = state.profile ?? {};
  const lines = ['Synthetic San Francisco trip plan.'];
  if (preferences.diet === 'Vegan, dairy-free, gluten-free') lines.push('Diet: vegan, dairy-free and gluten-free.');
  if (preferences.socialStatus === 'Socialize') lines.push('Social goal: meet people.');
  if (preferences.habits === 'Coffee and breakfast around 8 AM. Likes an evening drink.') {
    lines.push('Prefers coffee and breakfast around 8 AM and an evening drink.');
  }
  if (Number.isFinite(preferences.budget)) lines.push(`Trip budget: USD ${preferences.budget}.`);
  if (Number.isFinite(preferences.walkingGoal)) lines.push(`Walking goal: ${preferences.walkingGoal} steps.`);
  for (const slot of choiceSlots) {
    const item = catalog?.[slot]?.find(entry => entry.id === state.choices?.[slot]);
    if (item) lines.push(`${slot}: ${item.title}.`);
  }
  return lines.join('\n');
}

function matchedChunks(response, job) {
  if (!Array.isArray(response)) throw new Error('Unexpected Cognee search response');
  const results = new Set();
  const normalize = text => text.replace(/\s+/g, ' ').trim();
  const current = normalize(job.body);
  const add = entry => {
    if (Array.isArray(entry)) return entry.forEach(add);
    if (entry?.dataset_name && entry.dataset_name !== job.dataset) return;
    if (entry?.search_result !== undefined) return add(entry.search_result);
    const text = typeof entry === 'string' ? entry : entry?.text;
    if (typeof text !== 'string') return;
    const excerpt = normalize(text.replace('Atmos test memory ' + job.dataset, ''));
    if (excerpt && current.includes(excerpt)) results.add(excerpt.slice(0, 1600));
  };
  add(response);
  return [...results].slice(0, 5);
}

/** One worker per SQLite connection. The server supplies its authenticated visitor ID. */
export function createMemoryWorker(db, env = process.env, { fetchImpl = fetch, now = Date.now } = {}) {
  const config = configuration(env);
  db.exec(`
    CREATE TABLE IF NOT EXISTS test_memory_install (singleton INTEGER PRIMARY KEY CHECK(singleton=1), nonce TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS test_memory_jobs (
      dataset TEXT PRIMARY KEY, origin TEXT NOT NULL, owner TEXT NOT NULL, body TEXT, revision TEXT NOT NULL,
      state_version INTEGER NOT NULL, synced TEXT, lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, error TEXT
    );
  `);
  db.prepare('INSERT OR IGNORE INTO test_memory_install VALUES (1,?)').run(randomUUID());
  const {nonce} = db.prepare('SELECT nonce FROM test_memory_install WHERE singleton=1').get();
  const put = db.prepare(`
    INSERT INTO test_memory_jobs(dataset,origin,owner,body,revision,state_version) VALUES(?,?,?,?,?,?)
    ON CONFLICT(dataset) DO UPDATE SET body=excluded.body, revision=excluded.revision,
      state_version=excluded.state_version,
      synced=CASE WHEN revision=excluded.revision THEN synced END,
      attempts=CASE WHEN revision=excluded.revision THEN attempts ELSE 0 END,
      retry_at=CASE WHEN revision=excluded.revision THEN retry_at ELSE 0 END,
      error=CASE WHEN revision=excluded.revision THEN error END
    WHERE excluded.state_version >= state_version AND
      (excluded.revision <> revision OR excluded.state_version > state_version)
  `);
  const lookup = db.prepare('SELECT * FROM test_memory_jobs WHERE dataset=?');
  const ownerOf = id => {
    if (typeof id !== 'string' || !id.length) throw new TypeError('Missing authenticated visitor');
    return hash(JSON.stringify([nonce, id]));
  };
  const datasetOf = owner => 'atmos_test_' + hash(JSON.stringify([nonce, config.origin, owner])).slice(0, 40);
  const shared = 'shared-guide';
  let catalog, timer, active, stopped = false;
  const shutdown = new AbortController();

  function queueShared(value) {
    catalog = value;
    if (!config) return;
    const body = sharedSnapshot(catalog);
    put.run(datasetOf(shared), config.origin, shared, body, hash(body), 0);
  }

  function queueVisitor(id, state) {
    const owner = ownerOf(id);
    if (!state.started) {
      // Also record resets made while sync was disabled. Re-enabling the same
      // tenant will finish the deletion before the old snapshot can be recalled.
      const jobs = db.prepare('SELECT dataset,origin FROM test_memory_jobs WHERE owner=?').all(owner);
      for (const job of jobs) put.run(job.dataset, job.origin, owner, null, 'removed', state.revision);
      return;
    }
    if (!config) return;
    const body = visitorSnapshot(state, catalog);
    put.run(datasetOf(owner), config.origin, owner, body, hash(body), state.revision);
  }

  const brief = row => {
    if (!row) return 'empty';
    if (row.synced === row.revision) return row.body === null ? 'empty' : 'ready';
    if (row.lease_until > now()) return 'indexing';
    if (row.error) return row.error;
    return 'queued';
  };
  function status(id) {
    if (!config) return 'Local SQLite memory active. Cognee test sync is off.';
    return `Cognee test workspace · guide: ${brief(lookup.get(datasetOf(shared)))} · visitor: ${brief(lookup.get(datasetOf(ownerOf(id))))}.`;
  }

  async function api(path, method = 'GET', payload, allowMissing = false) {
    const headers = { 'X-Api-Key': config.key, Accept: 'application/json' };
    let body = payload;
    if (body && !(body instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(payload);
    }
    const options = {method, headers, body, redirect:'manual',
      signal: AbortSignal.any([shutdown.signal, AbortSignal.timeout(90_000)])};
    const url = new URL('/api/v1/' + path, config.origin);
    let response = await fetchImpl(url, options);
    if ([307,308].includes(response.status)) {
      const location = response.headers.get('location');
      const redirect = location && new URL(location, url);
      if (!redirect || redirect.origin !== url.origin || redirect.username || redirect.password ||
          redirect.pathname.replace(/\/$/, '') !== url.pathname.replace(/\/$/, '') ||
          redirect.search !== url.search) throw new Error('Unexpected redirect');
      response = await fetchImpl(redirect, options);
    }
    if (allowMissing && response.status === 404) return null;
    if (!response.ok) {
      const error = new Error('Cognee HTTP ' + response.status);
      error.httpStatus = response.status;
      const retry = response.headers.get('retry-after');
      error.retryMs = retry && /^\d+$/.test(retry) ? Number(retry)*1000 : Date.parse(retry ?? '') - now();
      throw error;
    }
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  async function deliver(job) {
    // Creation by name is idempotent. Re-resolve the ID on every attempt, so
    // an interrupted first write or reset does not leave a lost remote handle.
    const dataset = await api('datasets', 'POST', {name:job.dataset});
    if (dataset?.name !== job.dataset || !uuid.test(dataset.id)) throw new Error('Unexpected dataset');
    const path = 'datasets/' + dataset.id;
    if (job.body === null) {
      if (job.owner === shared) throw new Error('Invalid public dataset reset');
      await api(path, 'DELETE', undefined, true);
      return;
    }
    const docs = await api(path + '/data?limit=2');
    if (!Array.isArray(docs) || docs.length > 1) throw new Error('Unexpected dataset documents');
    const form = new FormData();
    const label = 'atmos-test-snapshot';
    form.set('data', new Blob(['Atmos test memory ' + job.dataset + '\n\n' + job.body], {type:'text/plain'}), label + '.txt');
    if (docs.length) {
      const doc = docs[0];
      if (!uuid.test(doc.id) || !(doc.label === label || [label, label+'.txt'].includes(doc.name))) {
        throw new Error('Unexpected document');
      }
      const result = await api('update?' + new URLSearchParams({dataset_id:dataset.id, data_id:doc.id}), 'PATCH', form);
      if (!['unchanged','full_rebuild','incremental'].includes(result?.status)) throw new Error('Indexing incomplete');
    } else {
      form.set('labels', JSON.stringify([label]));
      form.set('datasetName', job.dataset);
      form.set('datasetId', dataset.id);
      form.set('self_improvement', 'false');
      form.set('run_in_background', 'false');
      const result = await api('remember', 'POST', form);
      if (result?.status !== 'completed') throw new Error('Indexing incomplete');
    }
  }

  async function run() {
    if (!config || stopped) return;
    const rows = db.prepare(`SELECT dataset FROM test_memory_jobs WHERE origin=? AND synced IS NOT revision
      AND lease_until<=? AND retry_at<=? ORDER BY retry_at, dataset LIMIT 5`).all(config.origin, now(), now());
    for (const row of rows) {
      if (stopped) return;
      const lease = randomUUID();
      const job = db.prepare(`UPDATE test_memory_jobs SET lease=?,lease_until=?
        WHERE dataset=? AND synced IS NOT revision AND lease_until<=? AND retry_at<=? RETURNING *`)
        .get(lease, now()+600_000, row.dataset, now(), now());
      if (!job) continue;
      try {
        await deliver(job);
        db.prepare(`UPDATE test_memory_jobs SET synced=revision,attempts=0,error=NULL
          WHERE dataset=? AND revision=? AND lease=?`).run(job.dataset, job.revision, lease);
      } catch (error) {
        const httpError = Number.isInteger(error.httpStatus);
        const message = httpError ? 'retry after HTTP ' + error.httpStatus : 'retry pending';
        const backoff = Math.min(3600_000, 15_000 * 2 ** Math.min(job.attempts, 8));
        const retry = Number.isFinite(error.retryMs) ? error.retryMs : 0;
        db.prepare(`UPDATE test_memory_jobs SET attempts=attempts+1, retry_at=?, error=?
          WHERE dataset=? AND revision=? AND lease=?`)
          .run(now()+Math.max(backoff, retry), message, job.dataset, job.revision, lease);
      } finally {
        db.prepare('UPDATE test_memory_jobs SET lease=NULL,lease_until=0 WHERE dataset=? AND lease=?').run(job.dataset, lease);
      }
    }
  }

  function flush() {
    if (!active) active = run().finally(() => { active = undefined; });
    return active;
  }
  function start() {
    if (timer || stopped || !config) return;
    const tick = () => { void flush().catch(() => console.error('Atmos test memory worker could not process its queue.')); };
    tick();
    timer = setInterval(tick, 5000);
    timer.unref();
  }
  async function stop() {
    stopped = true;
    clearInterval(timer);
    shutdown.abort();
    await active;
  }

  async function recall(id, query, scope = 'shared') {
    if (typeof query !== 'string' || !query.trim() || query.length > 500) throw new TypeError('Enter a question of 1–500 characters.');
    if (!['shared','private'].includes(scope)) throw new TypeError('Unknown memory scope');
    const owner = ownerOf(id);
    if (!config || stopped) return {status:'offline', results:[]};
    const name = datasetOf(scope === 'shared' ? shared : owner);
    const job = lookup.get(name);
    if (brief(job) !== 'ready') return {status:brief(job), results:[]};
    try {
      const rows = await api('search', 'POST', {datasets:[name], sessionId:'atmos_' + hash(name+owner).slice(0,40),
        query:query.trim(), searchType:'CHUNKS', topK:5});
      if (stopped) return {status:'offline', results:[]};
      const latest = lookup.get(name);
      if (brief(latest) !== 'ready' || latest.revision !== job.revision) return {status:'changed', results:[]};
      return {status:'ready', results:matchedChunks(rows, job)};
    } catch {
      return {status:'unavailable', results:[]};
    }
  }
  return {queueShared, queueVisitor, status, start, stop, flush, recall};
}

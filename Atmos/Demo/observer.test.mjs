import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { createObserver } from './observer.mjs';

const forecast = (values = [0, 0, 0], date = '2026-11-21') => ({
  properties: { periods: values.map((value, i) => ({
    startTime: `${date}T0${i + 2}:00:00-08:00`, probabilityOfPrecipitation: { value },
  })) },
});
const organizer = (eventStatus = 'EventScheduled') => `<script type="application/ld+json">${JSON.stringify({
  '@graph': [{ '@type': 'Event', name: 'Personal Agents Hackathon', startDate: '2026-11-20T09:30:00-08:00',
    endDate: '2026-11-20T19:30:00-08:00', eventStatus: 'https://schema.org/' + eventStatus }],
})}</script>`;

function mockFeeds() {
  const feeds = { weather: forecast(), event: organizer(), menu: '%PDF-1.7 test document' };
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (url.includes('api.weather.gov')) return Response.json(feeds.weather);
    if (url.includes('luma.com')) return new Response(feeds.event, { headers: { 'Content-Type': 'text/html' } });
    if (feeds.menu === null) throw new Error('offline');
    return new Response(feeds.menu, { headers: { 'Content-Type': 'application/pdf' } });
  };
  return { feeds, requests, fetchImpl };
}

test('source checking is opt-in, nonblocking and coalesces concurrent starts', async t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  const { requests, fetchImpl } = mockFeeds();
  const off = createObserver(db, { fetchImpl });
  await off.start();
  assert.equal(requests.length, 0);
  assert.equal(off.snapshot().weather, undefined);
  const on = createObserver(db, { enabled: true, fetchImpl });
  const first = on.start();
  assert.equal(requests.length, 0);
  assert.strictEqual(on.start(), first);
  await first;
  await on.stop();
  const { sources, weather } = on.snapshot();
  assert.equal(requests.length, 3);
  assert.ok(requests.every(r => r.options.redirect === 'error' && r.options.signal));
  assert.match(weather, /2 AM 0%, 3 AM 0%, 4 AM 0%/);
  assert.equal(sources[1].facts.start, '2026-11-20T17:30:00.000Z');
  assert.equal(sources[1].facts.end, '2026-11-21T03:30:00.000Z');
  assert.equal(sources[1].facts.eventStatus, 'Scheduled');
  assert.match(sources[2].facts.sha256, /^[0-9a-f]{64}$/);
});

test('date-specific weather and last good evidence survive failures, restarts, and unchanged feeds', async t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  const { feeds, fetchImpl } = mockFeeds();
  let now = Date.parse('2026-11-20T22:59:51Z');
  const make = () => createObserver(db, { enabled: true, fetchImpl, clock: () => now });
  async function run() {
    const observer = make();
    await observer.start();
    await observer.stop();
    return observer.snapshot();
  }
  const initial = await run();
  now += 1800000;
  feeds.event = '<meta name="request-id" content="dynamic">' + organizer();
  const same = await run();
  assert.equal(db.prepare('SELECT count(*) AS n FROM source_observations').get().n, 3);
  for (let i = 0; i < 3; i++) {
    assert.equal(same.sources[i].changedAt, initial.sources[i].changedAt);
    assert.notEqual(same.sources[i].checkedAt, initial.sources[i].checkedAt);
  }
  now += 1800000;
  feeds.weather = forecast([98, 100, 97], '2026-11-22');
  feeds.event = '<html>A link to the event</html>';
  feeds.menu = null;
  const stale = await run();
  assert.match(stale.weather, /Last verified.*2 AM 0%, 3 AM 0%, 4 AM 0%/);
  assert.doesNotMatch(stale.weather, /98%|100%|97%/);
  assert.match(stale.sources[1].status, /structured event details unavailable/);
  assert.equal(stale.sources[1].facts.eventStatus, 'Scheduled');
  for (let i = 0; i < 3; i++) {
    assert.equal(stale.sources[i].changedAt, initial.sources[i].changedAt);
    assert.equal(stale.sources[i].lastGoodAt, same.sources[i].checkedAt);
  }
  now += 1800000;
  feeds.weather = forecast([0, null, 20]);
  feeds.event = organizer('EventPostponed');
  feeds.menu = '%PDF-1.7 new menu';
  const updated = await run();
  assert.match(updated.sources[0].status, /unavailable/);
  assert.equal(updated.sources[1].facts.eventStatus, 'Postponed');
  assert.notEqual(updated.sources[2].changedAt, initial.sources[2].changedAt);
  assert.notEqual(updated.sources[2].facts.sha256, initial.sources[2].facts.sha256);
  now += 1800000;
  feeds.weather = forecast([20, 30, 40]);
  const recovered = await run();
  assert.match(recovered.weather, /2 AM 20%, 3 AM 30%, 4 AM 40%/);
  assert.equal(recovered.sources[0].changedAt, recovered.sources[0].checkedAt);
});

test('stopping an in-flight update preserves the previous observation', async () => {
  const db = new DatabaseSync(':memory:');
  let notify;
  const started = new Promise(resolve => { notify = resolve; });
  const fetchImpl = (_, { signal }) => new Promise((_, reject) => {
    notify();
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
  const observer = createObserver(db, { enabled: true, fetchImpl });
  observer.start();
  await started;
  await observer.stop();
  assert.ok(observer.snapshot().sources.every(row => row.checkedAt === null));
  db.close();
});

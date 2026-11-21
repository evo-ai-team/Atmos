import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createMemoryWorker } from './memory.mjs';

const env = {ATMOS_TEST_COGNEE_URL:'https://mock-test.aws.cognee.ai', ATMOS_TEST_COGNEE_KEY:'mock-only'};
const catalog = {
  date:'2026-11-20', intro:'private briefing',
  contacts:[{title:'unpublished friend'}], alert:{title:'private footage'},
  lunch:[{id:'bowl',title:'Rice bowl',notes:'Prepared with tofu.', sources:[{label:'Menu',url:'https://example.org/menu'}]},
    {id:'salad',title:'Green salad'}, {id:'soup',title:'Tomato soup'}],
};
const visitor = (lunch, revision=1) => ({started:true,revision,
  profile:{budget:71342,walkingGoal:87321,workplaceNote:'private workplace note', discretion:true, trip:'private trip',
    socialStatus:'Socialize', diet:'Vegan, dairy-free, gluten-free'},
  transcript:'private transcript', invitations:['private friend'], choices:{lunch}, confirmedSlots:['lunch'],
  expenses:[{label:'private ledger'}]});

// These tests explicitly inject a local transport. Nothing resolves the example host.
function harness() {
  const db = new DatabaseSync(':memory:');
  const datasets = new Map();
  const calls = [];
  const control = {time:1000, fail:false};
  const fetchImpl = async (url, options) => {
    const path = url.pathname.replace('/api/v1/','');
    calls.push({path,method:options.method});
    assert.equal(url.origin, env.ATMOS_TEST_COGNEE_URL);
    assert.equal(options.headers['X-Api-Key'], 'mock-only');
    if (control.fail) return new Response(null, {status:429, headers:{'Retry-After':'55'}});
    if (path === 'datasets') {
      const {name} = JSON.parse(options.body);
      if (!datasets.has(name)) datasets.set(name,{id:randomUUID(),name});
      const {id} = datasets.get(name);
      return Response.json({id,name});
    }
    const byId = id => [...datasets.values()].find(row => row.id === id);
    if (path.endsWith('/data')) {
      const row = byId(path.split('/')[1]);
      return Response.json(row.doc ? [{id:row.doc,label:'atmos-test-snapshot'}] : []);
    }
    if (path === 'remember' || path === 'update') {
      const id = path === 'update' ? url.searchParams.get('dataset_id') : options.body.get('datasetId');
      const row = byId(id);
      if (path === 'update') assert.equal(url.searchParams.get('data_id'), row.doc);
      if (control.onUpload) await control.onUpload();
      row.body = await options.body.get('data').text();
      row.doc ??= randomUUID();
      return Response.json({status:path === 'remember' ? 'completed' : 'incremental'});
    }
    if (path === 'search') {
      const payload = JSON.parse(options.body);
      assert.equal(payload.datasets.length,1);
      assert.equal(payload.searchType,'CHUNKS');
      const row = datasets.get(payload.datasets[0]);
      return Response.json([{dataset_name:row.name,search_result:[{text:row.body},{text:'stale unrelated result'}]},
        {dataset_name:'other_user',search_result:[{text:'private across scopes'}]}]);
    }
    if (options.method === 'DELETE') {
      const row = byId(path.split('/')[1]);
      datasets.delete(row.name);
      return new Response(null, {status:204});
    }
    throw new Error('Unexpected mock path');
  };
  const makeWorker = () => createMemoryWorker(db,env,{fetchImpl, now:()=>control.time});
  const worker = makeWorker();
  worker.queueShared(catalog);
  return {db, datasets, calls, control, worker, makeWorker};
}

test('offline mode stores no cloud jobs and requires explicit test credentials', async () => {
  const db = new DatabaseSync(':memory:');
  const worker = createMemoryWorker(db,{COGNEE_BASE_URL:env.ATMOS_TEST_COGNEE_URL,COGNEE_API_KEY:'ignored'}, {
    fetchImpl:()=>assert.fail('Offline worker attempted a request'),
  });
  worker.queueShared(catalog);
  worker.queueVisitor('a', visitor('bowl'));
  worker.start();
  await worker.flush();
  assert.deepEqual(await worker.recall('a','What is my lunch?','private'),{status:'offline',results:[]});
  assert.match(worker.status('a'), /sync is off/);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM test_memory_jobs').get().n,0);
  assert.throws(() => createMemoryWorker(db,{...env,ATMOS_TEST_COGNEE_URL:'https://outside.example.org'}));
  await worker.stop();
  db.close();
});

test('per-visitor search, replacement and reset are isolated from the public guide', async () => {
  const {worker,db,datasets,calls} = harness();
  worker.queueVisitor('empty',{...visitor('bowl'),confirmedSlots:[]});
  assert.equal(db.prepare("SELECT count(*) AS n FROM test_memory_jobs WHERE owner!='shared-guide'").get().n,0);
  worker.queueVisitor('A',visitor('bowl')); worker.queueVisitor('B',visitor('salad'));
  await worker.flush();
  assert.equal(datasets.size,3);
  const texts = [...datasets.values()].map(v=>v.body).join('\n');
  for (const forbidden of ['private briefing','private transcript','private workplace','private trip',
    '71342','87321','Social goal','gluten-free','unpublished friend','private footage','private friend','private ledger']) assert.ok(!texts.includes(forbidden));
  const result = await worker.recall('A','Lunch?','private');
  assert.equal(result.status,'ready'); assert.equal(result.results.length,1);
  assert.match(result.results[0], /Rice bowl/); assert.doesNotMatch(result.results[0], /Green salad|stale|across/);
  const shared = await worker.recall('B','What food?','shared');
  assert.match(shared.results[0],/example.org\/menu/); assert.doesNotMatch(shared.results[0], /budget/i);
  worker.queueVisitor('A',visitor('soup',2));
  assert.equal((await worker.recall('A','Lunch?','private')).status,'queued');
  await worker.flush();
  assert.match((await worker.recall('A','Lunch?','private')).results[0], /Tomato soup/);
  assert.ok(calls.some(req=>req.method==='PATCH'));
  const before = calls.length;
  worker.queueVisitor('A',visitor('soup',3)); await worker.flush();
  assert.equal(calls.length,before);
  worker.queueVisitor('A',{started:false,revision:4});
  await worker.flush();
  assert.equal(datasets.size,2);
  assert.equal((await worker.recall('A','Lunch?','private')).status,'empty');
  assert.match((await worker.recall('B','Lunch?','private')).results[0], /Green salad/);
  worker.queueVisitor('A',visitor('soup',3)); await worker.flush();
  assert.equal(datasets.size,2);
  await worker.stop(); db.close();
});

test('removing and restoring lunch updates only the visitor’s indexed plan', async () => {
  const {worker,db} = harness();
  try {
    worker.queueVisitor('A',visitor('bowl'));
    await worker.flush();
    worker.queueVisitor('A',{...visitor('bowl',2),skippedSlots:['lunch']});
    await worker.flush();
    const skipped = (await worker.recall('A','lunch','private')).results.join(' ');
    assert.match(skipped,/lunch: skipped for this visit/);
    assert.doesNotMatch(skipped,/Rice bowl/);
    assert.match((await worker.recall('A','lunch','shared')).results.join(' '),/Rice bowl/);
    worker.queueVisitor('A',{...visitor('bowl',3),skippedSlots:[]});
    await worker.flush();
    assert.match((await worker.recall('A','lunch','private')).results.join(' '),/lunch: Rice bowl/);
  } finally {
    await worker.stop();
    db.close();
  }
});

test('the private index remembers confirmed evening modes without route endpoints', async () => {
  const {worker,db} = harness();
  try {
    const state = visitor('bowl');
    state.choices.toDinner = 'walk';
    state.choices.toNightlife = 'waymo';
    state.confirmedSlots = ['toDinner','toNightlife'];
    state.privateRoute = {origin:'Private departure address',destination:'Private arrival address'};
    worker.queueVisitor('A',state);
    await worker.flush();
    const snapshot = (await worker.recall('A','travel','private')).results.join(' ');
    assert.match(snapshot,/Travel to dinner: walking/);
    assert.match(snapshot,/Travel to nightlife: Waymo/);
    assert.doesNotMatch(snapshot,/Private departure|Private arrival/);
  } finally { await worker.stop(); db.close(); }
});

test('rate limits survive worker replacement and a fresh edit supersedes an in-flight revision', async () => {
  const {worker,db,control,makeWorker,datasets} = harness();
  control.fail = true;
  await worker.flush();
  assert.match(worker.status('A'), /429/);
  await worker.stop();
  control.fail = false;
  const next = makeWorker(); next.queueShared(catalog);
  control.time += 54_999; await next.flush(); assert.equal(datasets.size,0);
  control.time++; await next.flush(); assert.equal(datasets.size,1);
  next.queueVisitor('A', visitor('bowl'));
  let began, release;
  const entered = new Promise(resolve => { began=resolve; });
  control.onUpload = () => { began(); return new Promise(resolve => { release=resolve; }); };
  const working = next.flush();
  await entered;
  next.queueVisitor('A',visitor('soup',2));
  release(); await working;
  assert.equal((await next.recall('A','Lunch?','private')).status,'queued');
  control.onUpload = null;
  await next.flush();
  const fresh = await next.recall('A','Lunch?','private');
  assert.match(fresh.results[0],/Tomato soup/); assert.doesNotMatch(fresh.results[0],/Rice bowl/);
  await next.stop(); db.close();
});

test('a reset made offline still clears the matching remote dataset when the tenant reconnects', async () => {
  const {worker,db,makeWorker,datasets} = harness();
  worker.queueVisitor('A',visitor('bowl')); worker.queueVisitor('B',visitor('salad'));
  await worker.flush(); await worker.stop();
  const offline = createMemoryWorker(db,{}, {fetchImpl:()=>assert.fail('unexpected offline request')});
  offline.queueVisitor('A',{started:false, revision:10});
  offline.queueVisitor('A',{started:false, revision:11});
  await offline.stop();
  const connected = makeWorker(); connected.queueShared(catalog);
  connected.queueVisitor('A',visitor('soup',10));
  assert.equal((await connected.recall('A','Lunch?','private')).results.length,0);
  await connected.flush();
  assert.equal(datasets.size,2);
  assert.match((await connected.recall('B','Lunch?','private')).results[0],/Green salad/);
  assert.equal((await connected.recall('A','Lunch?','private')).status,'empty');
  await connected.stop(); db.close();
});

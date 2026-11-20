import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemo } from './server.mjs';
import { catalog, intro, newState, updateState, trackerFor, guideForVisit, itineraryBriefing, searchLocalMemory } from './scenario.mjs';

const start = () => updateState(newState(),{action:'start',transcript:intro});
const choose = (s,slot,id) => updateState(s,{action:'choose',slot,id});
test('each itinerary branch yields chronological, linked route legs and finite daily totals', () => {
  for (const t of catalog.transit.filter(t=>t.available !== false))
    for (const am of catalog.breakfast)
      for (const l of catalog.lunch)
        for (const d of catalog.dinner)
          for (const n of catalog.nightlife) {
            const s = start();
            s.choices = {transit:t.id,breakfast:am.id,lunch:l.id,dinner:d.id,nightlife:n.id};
            const track = trackerFor(s);
            const times = track.lines.map(line=>line.time);
            assert.deepEqual(times,[...times].sort());
            assert.ok(track.cost >= t.price + am.price + l.price + d.price + n.price - 0.01);
            assert.ok(Number.isFinite(track.steps) && track.steps > 0);
            assert.equal(track.calories,Math.round(track.steps*0.04));
            const first = new URL(track.lines[0].url);
            assert.equal(first.searchParams.get('destination'),am.address);
            assert.equal(first.searchParams.get('travelmode'),t.id==='muni'?'transit':'driving');
            const lastLeg = track.lines.filter(l=>l.url?.includes('/maps/dir/') && l.title.includes('min')).at(-1);
            assert.equal(new URL(lastLeg.url).searchParams.get('origin'),d.address);
          }
});

test('notification updates the route and clears dinner-specific drafts without spending money', () => {
  let s = start();
  const current = catalog.dinner.find(o=>o.reservable);
  s = choose(s,'dinner',current.id);
  s = updateState(s,{action:'invite',id:'gio'});
  s = updateState(s,{action:'reserve'});
  s = choose(s,'nightlife',catalog.nightlife[0].id);
  assert.equal(s.alert,'shown');
  s = updateState(s,{action:'expense',label:'Breakfast',amount:11.5});
  s = updateState(s,{action:'reroute'});
  assert.notEqual(s.choices.dinner,current.id);
  assert.deepEqual(s.invitations,[]); assert.equal(s.reservation,null);
  assert.equal(trackerFor(s).spent,11.5);
  const fresh = updateState(s,{action:'reset'});
  assert.equal(fresh.started,false); assert.equal(fresh.transcript,''); assert.deepEqual(fresh.expenses,[]);
});

test('spoken details live in private memory and absence of a work conflict suppresses that alert', () => {
  const s = updateState(newState(),{action:'start',transcript:'Plan a Richmond SF itinerary. My budget is under $125 and I want to walk 3k steps.'});
  assert.equal(s.profile.budget,125); assert.equal(s.profile.walkingGoal,3000);
  assert.equal(s.profile.workplaceNote,undefined);
  assert.equal(choose(s,'nightlife',catalog.nightlife[0].id).alert,'idle');
  assert.throws(()=>updateState(s,{action:'alert'}));
  assert.throws(()=>updateState(s,{action:'invite',id:'gio'}));
  assert.ok(start().profile.trip.includes('Singapore'));
});

test('all meal skip combinations update stops, directions, spending, briefing and personal recall', () => {
  const meals = ['breakfast','lunch','dinner'];
  const original = choose(start(),'transit','taxi');
  const complete = trackerFor(original);
  for (let mask=0; mask<8; mask++) {
    let state = original;
    const skipped = meals.filter((_,index) => mask & 1<<index);
    for (const slot of skipped) state = updateState(state,{action:'skip',slot});
    const tracker = trackerFor(state);
    const guide = guideForVisit(catalog,state);
    const briefing = itineraryBriefing(state,tracker).join(' ');
    const routeLegs = tracker.lines.filter(line => line.title.includes(' · ~'));
    const first = new URL(routeLegs[0].url).searchParams;
    const last = new URL(routeLegs.at(-1).url).searchParams;
    assert.equal(first.get('destination'),skipped.includes('breakfast') ? guide.event.address : guide.breakfast[0].address);
    assert.equal(last.get('origin'),skipped.includes('dinner') ? guide.event.address : guide.dinner[0].address);
    assert.equal(new URL(guide.nightlife[0].url).searchParams.get('origin'), last.get('origin'));
    assert.equal(tracker.calories,Math.round(tracker.steps*0.04));
    const times = tracker.lines.map(line => line.time);
    assert.deepEqual(times,[...times].sort());
    assert.deepEqual(state.skippedSlots,skipped);
    for (const slot of meals) {
      const venue = guide[slot].find(option => option.id === state.choices[slot]);
      assert.equal(tracker.lines.some(line => line.title === venue.title),!skipped.includes(slot));
      assert.equal(briefing.includes(venue.title),!skipped.includes(slot));
      if (skipped.includes(slot)) {
        const facts = searchLocalMemory(guide,state,'private',slot).join(' ');
        assert.ok(facts.includes(slot+': skipped'));
        assert.ok(!facts.includes(venue.title));
      }
    }
    const removedPrices = skipped.reduce((sum,slot) => sum+guide[slot][0].price,0);
    // The default breakfast requires a second taxi. Dropping it removes that fare too.
    // The default evening uses one Muni fare even when the dinner stop is skipped.
    const taxiFare = skipped.includes('breakfast') ? guide.transit.find(t=>t.id==='taxi').price : 0;
    assert.equal(tracker.cost,Math.round((complete.cost-removedPrices-taxiFare)*100)/100);
    for (const slot of skipped) state = choose(state,slot,state.choices[slot]);
    assert.deepEqual(trackerFor(state),complete);
  }
});

test('skipped dinner clears drafts, supports repeated removal, restoration and rerouting in legacy sessions', () => {
  const legacy = start();
  delete legacy.skippedSlots;
  const venue = catalog.dinner.find(o => o.reservable);
  let state = choose(legacy,'dinner',venue.id);
  state = updateState(state,{action:'reserve'});
  state = updateState(state,{action:'invite',id:'gio'});
  state = updateState(state,{action:'expense',label:'Paid earlier',amount:12});
  state = updateState(state,{action:'skip',slot:'dinner'});
  assert.equal(state.choices.dinner,venue.id);
  assert.deepEqual(state.invitations,[]);
  assert.equal(state.reservation,null);
  assert.ok(!state.confirmedSlots.includes('dinner'));
  assert.equal(trackerFor(state).spent,12);
  assert.deepEqual(updateState(state,{action:'skip',slot:'dinner'}),state);
  assert.throws(()=>updateState(state,{action:'invite',id:'gio'}));
  assert.throws(()=>updateState(state,{action:'reserve'}));
  assert.throws(()=>updateState(state,{action:'skip',slot:'transit'}));
  assert.throws(()=>updateState(newState(),{action:'skip',slot:'lunch'}));
  const restored = updateState(updateState(state,{action:'alert'}),{action:'reroute'});
  assert.ok(restored.confirmedSlots.includes('dinner'));
  assert.ok(!restored.skippedSlots.includes('dinner'));
  assert.notEqual(restored.choices.dinner,venue.id);
});

async function listen(filename) {
  const server = createDemo({filename});
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  return {url:'http://127.0.0.1:'+server.address().port,close:()=>new Promise(resolve=>server.close(resolve))};
}
const post = (url,data,extra={}) => fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...extra},body:JSON.stringify(data)});
test('approval saves the displayed dinner text locally for both demo contacts and survives a restart',async () => {
  const dir = await mkdtemp(join(tmpdir(),'atmos-text-test-'));
  const filename = join(dir,'texts.sqlite');
  let app = await listen(filename);
  try {
    const initial = await fetch(app.url+'/api/demo');
    const Cookie = initial.headers.get('set-cookie').split(';')[0];
    const preview = await initial.json();
    const submit = data => post(app.url+'/api/demo',data,{Cookie});
    const read = async () => (await fetch(app.url+'/api/demo',{headers:{Cookie}})).json();
    const draft = preview.dinnerTextDraft;
    assert.deepEqual(preview.state.sentDinnerTexts,[]);
    assert.deepEqual(draft.recipientIds,['gio','andrew']);
    assert.deepEqual(draft.recipients,['Gio L.','Andrew S.']);
    assert.equal(draft.time,preview.previewTracker.lines.find(line=>line.slot==='dinner').time);
    assert.ok(draft.body.includes(draft.venue) && draft.body.includes(draft.address));
    assert.ok(new URL(draft.url).searchParams.get('query').includes(draft.address));
    const send = {action:'sendDinnerText',key:draft.key};
    assert.equal((await submit(send)).status,400);

    const started = await (await submit({action:'start',transcript:intro})).json();
    assert.deepEqual(started.dinnerTextDraft,draft);
    assert.equal((await submit({...send,key:'old-draft'})).status,400);
    assert.equal((await submit({...send,recipients:['custom recipient']})).status,400);
    assert.equal((await submit({...send,revision:0})).status,409);
    assert.deepEqual((await read()).state.sentDinnerTexts,[]);
    const saved = await (await submit({...send,revision:started.state.revision})).json();
    const [message] = saved.state.sentDinnerTexts;
    const {id,sentAt,...snapshot} = message;
    assert.ok(id);
    assert.equal(new Date(sentAt).toISOString(),sentAt);
    assert.deepEqual(snapshot,draft);
    assert.deepEqual(saved.state.invitations,[]);
    const repeated = await (await submit({...send,revision:saved.state.revision})).json();
    assert.deepEqual(repeated.state,saved.state);

    const changedDinner = catalog.dinner.find(option=>option.id!==draft.dinnerId && option.available!==false);
    const changed = await (await submit({action:'choose',slot:'dinner',id:changedDinner.id})).json();
    assert.notEqual(changed.dinnerTextDraft.key,draft.key);
    assert.deepEqual(changed.state.sentDinnerTexts,[message]);
    assert.equal((await submit({...send,revision:changed.state.revision})).status,400);
    const second = await (await submit({action:'sendDinnerText',key:changed.dinnerTextDraft.key})).json();
    const history = second.state.sentDinnerTexts;
    assert.equal(history.length,2);
    assert.deepEqual(history[0],message);
    assert.equal(history[1].venue,changedDinner.title);
    assert.notEqual(history[0].id,history[1].id);
    const skipped = await (await submit({action:'skip',slot:'dinner'})).json();
    assert.equal(skipped.dinnerTextDraft,null);
    assert.equal((await submit({action:'sendDinnerText',key:changed.dinnerTextDraft.key})).status,400);

    await app.close(); app = await listen(filename);
    assert.deepEqual((await read()).state.sentDinnerTexts,history);
    const other = await (await fetch(app.url+'/api/demo')).json();
    assert.deepEqual(other.state.sentDinnerTexts,[]);
    const reset = await (await submit({action:'reset'})).json();
    assert.deepEqual(reset.state.sentDinnerTexts,[]);
    assert.deepEqual(reset.dinnerTextDraft,draft);
  } finally {
    await app.close();
    await rm(dir,{recursive:true,force:true});
  }
});

test('browser memories are isolated and survive a restart, native handoffs are single use',async () => {
  const dir = await mkdtemp(join(tmpdir(),'atmos-trip-test-'));
  let app = await listen(join(dir,'test.sqlite'));
  try {
    let res = await fetch(app.url+'/api/demo');
    const cookie = res.headers.get('set-cookie').split(';')[0];
    const preview = await res.json();
    assert.equal(preview.state.started,false);
    assert.deepEqual(preview.state.choices,{});
    assert.deepEqual(preview.tracker.lines,[]);
    assert.ok(preview.previewTracker.lines.length > 0);
    res = await post(app.url+'/api/demo',{action:'start',transcript:intro},{Cookie:cookie});
    const built = await res.json();
    assert.deepEqual(preview.previewTracker,built.tracker);
    assert.equal(built.state.profile.discretion,true);
    assert.match(built.briefing[0],/9:30 AM/);
    assert.ok(built.briefing.join(' ').includes('1:30 PM'));
    const recall = (scope,query,headers={}) => post(app.url+'/api/recall',{scope,query},headers).then(r=>r.json());
    assert.ok((await recall('private','boss',{Cookie:cookie})).results.some(f=>f.includes('sick')));
    assert.equal((await recall('private','boss')).results.length,0);
    assert.equal((await recall('shared','boss',{Cookie:cookie})).results.length,0);
    assert.ok((await recall('shared','tofu')).results.some(f=>f.includes('Proper Food')));
    let other = await (await fetch(app.url+'/api/demo')).json();
    assert.equal(other.state.transcript,''); assert.equal(other.state.profile.workplaceNote,undefined);
    res = await post(app.url+'/api/demo',{action:'reset',revision:0},{Cookie:cookie});
    assert.equal(res.status,409);
    res = await post(app.url+'/api/demo',{action:'skip',slot:'breakfast'},{Cookie:cookie});
    assert.equal(res.status,200);
    await app.close(); app = await listen(join(dir,'test.sqlite'));
    const saved = await (await fetch(app.url+'/api/demo',{headers:{Cookie:cookie}})).json();
    assert.equal(saved.state.transcript,intro);
    assert.deepEqual(saved.state.skippedSlots,['breakfast']);
    assert.equal(new URL(saved.tracker.lines[0].url).searchParams.get('destination'),catalog.event.address);
    res = await post(app.url+'/api/handoff',{transcript:'Richmond SF for the weekend'},{'X-Atmos-Client':'native-demo'});
    assert.equal(res.status,201); const {ticket} = await res.json();
    res = await fetch(app.url+'/handoff/'+ticket,{redirect:'manual'});
    assert.equal(res.status,303); const nativeCookie = res.headers.get('set-cookie').split(';')[0];
    assert.equal((await fetch(app.url+'/handoff/'+ticket)).status,410);
    other = await (await fetch(app.url+'/api/demo',{headers:{Cookie:nativeCookie}})).json();
    assert.equal(other.state.transcript,'Richmond SF for the weekend');
    assert.equal(other.state.profile.discretion,false);
  } finally { await app.close(); await rm(dir,{recursive:true,force:true}); }
});

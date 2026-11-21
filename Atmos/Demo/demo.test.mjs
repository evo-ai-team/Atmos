import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemo } from './server.mjs';
import { routeSection, routeSlots } from './public/views.js';
import { catalog, intro, newState, updateState, trackerFor, guideForVisit, itineraryBriefing, searchLocalMemory } from './scenario.mjs';

const start = () => updateState(newState(),{action:'start',transcript:intro});
const choose = (s,slot,id) => updateState(s,{action:'choose',slot,id});
test('all stop icons preview the named option before offering confirmation', () => {
  for (const slot of routeSlots) {
    let state = start();
    if (slot === 'toDinner') state = choose(state,'dinner',catalog.dinner[0].id);
    if (slot === 'toNightlife') state = choose(state,'nightlife',catalog.nightlife[0].id);
    const data = {catalog:guideForVisit(catalog,state),state,tracker:trackerFor(state)};
    const options = slot === 'event' ? [catalog.event] : data.catalog[slot];
    const menu = routeSection(data,slot);
    assert.doesNotMatch(menu,/data-action="choose"/);
    for (const item of options) {
      assert.ok(menu.includes(`data-preview="${item.id}"`));
      const preview = routeSection(data,slot,item.id);
      assert.ok(preview.includes(`data-action="choose" data-slot="${slot}" data-id="${item.id}"`));
      assert.ok(preview.includes(`data-options="${slot}"`));
      if (['transit','toDinner','toNightlife'].includes(slot)) {
        assert.ok(preview.includes(item.id === 'walk' ? item.minutes+' min' : item.wait));
        if (slot !== 'transit') assert.ok(preview.includes('km'));
      }
      else assert.ok(preview.includes(`data-photo-id="${item.id}"`));
    }
    const saved = {...data,state:choose(state,slot,options[0].id)};
    assert.match(routeSection(saved,slot),/aria-label="Return to /);
    assert.match(routeSection(saved,slot,null),/on your route/);
  }
});

test('each itinerary branch yields chronological, linked route legs and finite daily totals', () => {
  for (const t of catalog.transit.filter(t=>t.available !== false))
    for (const am of catalog.breakfast)
      for (const l of catalog.lunch)
        for (const d of catalog.dinner)
          for (const n of catalog.nightlife) {
            const s = start();
            s.choices = {transit:t.id,breakfast:am.id,lunch:l.id,dinner:d.id,nightlife:n.id,toDinner:'muni',toNightlife:'muni'};
            s.confirmedSlots = Object.keys(s.choices);
            const track = trackerFor(s);
            const times = track.lines.map(line=>line.time);
            assert.deepEqual(times,[...times].sort());
            assert.ok(track.cost >= t.price + am.price + l.price + d.price + n.price - 0.01);
            assert.ok(Number.isFinite(track.steps) && track.steps > 0);
            assert.equal(track.calories,Math.round(track.steps*0.04));
            const first = new URL(track.lines[0].url);
            assert.equal(first.searchParams.get('destination'),am.address);
            assert.equal(first.searchParams.get('travelmode'),t.id==='walk'?'walking':t.id==='muni'?'transit':'driving');
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
  assert.equal(fresh.started,false); assert.ok(!Object.hasOwn(fresh,'transcript')); assert.deepEqual(fresh.expenses,[]);
});

test('evening travel choices connect the selected venues and update only the confirmed mode, totals and invitation time', () => {
  const venues = choose(choose(start(),'dinner','dinner-lataqueria'),'nightlife',catalog.nightlife[0].id);
  const base = trackerFor(venues);
  assert.deepEqual(base.legs,[]);
  const transfers = trackerFor(choose(choose(venues,'toDinner','muni'),'toNightlife','muni'));
  assert.equal(transfers.legs[1].price,0); // A second Muni boarding within the transfer window.
  const expectedIds = ['walk','muni','waymo','tesla','taxi'].sort();
  const toMins = time => time.split(':').reduce((value,part)=>value*60+Number(part),0);
  for (const id of expectedIds) {
    const s = choose(venues,'toDinner',id);
    assert.ok(s.confirmedSlots.includes('toDinner'));
    const guide = guideForVisit(catalog,s);
    for (const slot of ['toDinner','toNightlife']) {
      assert.deepEqual(guide[slot].map(option=>option.id).sort(),expectedIds);
      for (const option of guide[slot]) {
        assert.ok(option.originName && option.destinationName && option.wait && option.notes);
        const params = new URL(option.url).searchParams;
        assert.equal(params.get('origin'),option.origin);
        assert.equal(params.get('destination'),option.destination);
        assert.equal(params.get('travelmode'),option.id==='muni'?'transit':option.id==='walk'?'walking':'driving');
        assert.equal(toMins(option.arrivesAt)-toMins(option.time),option.minutes);
        assert.ok(option.distanceKm>0 && option.steps>0 && option.price>=0);
      }
    }
    for (const next of expectedIds) {
      const fullyChosen = choose(s,'toNightlife',next);
      const tracker = trackerFor(fullyChosen);
      assert.deepEqual(tracker.legs.map(leg=>leg.id),[id,next]);
      assert.equal(tracker.legs[0].origin,catalog.event.address);
      assert.equal(tracker.legs[1].origin,tracker.legs[0].destination);
      const delta = (items,field) => items.reduce((sum,item)=>sum+item[field],0)-base.legs.reduce((sum,item)=>sum+item[field],0);
      assert.equal(tracker.steps,base.steps+delta(tracker.legs,'steps'));
      assert.equal(tracker.cost,Math.round((base.cost+delta(tracker.legs,'price'))*100)/100);
      assert.equal(tracker.calories,Math.round(tracker.steps*0.04));
      assert.equal(tracker.lines.find(line=>line.slot==='dinner').time,tracker.legs[0].arrivesAt);
    }
  }
  const skipped = updateState(choose(venues,'toNightlife','taxi'),{action:'skip',slot:'dinner'});
  assert.deepEqual(guideForVisit(catalog,skipped).toDinner,[]);
  assert.throws(()=>choose(skipped,'toDinner','walk'));
  const [only] = trackerFor(skipped).legs;
  assert.deepEqual(trackerFor(skipped).legs.map(leg=>leg.slot),['toNightlife']);
  assert.equal(only.origin,catalog.event.address);
  assert.equal(only.id,'taxi');
  assert.throws(()=>choose(venues,'toNightlife','unlisted-car'));
});

test('long walking routes show real ordering, late hackathon arrival and closing-time conflicts', () => {
  let s = choose(choose(start(),'breakfast',catalog.breakfast[0].id),'transit','walk');
  s = choose(s,'dinner','dinner-lataqueria');
  s = choose(s,'nightlife','game-night');
  s = choose(s,'toDinner','walk');
  s = choose(s,'toNightlife','walk');
  const t = trackerFor(s);
  const guide = guideForVisit(catalog,s);
  const morning = guide.transit.find(mode=>mode.id==='walk');
  assert.equal(morning.url,t.lines[0].url);
  assert.equal(morning.time,t.lines[0].time);
  assert.equal(t.lines.find(l=>l.title.startsWith('Arrive at the Loft')).time,'09:40');
  assert.deepEqual(t.lines.map(l=>l.time),t.lines.map(l=>l.time).sort());
  assert.match(t.legs[0].timingNote,/closing times/);
  assert.match(t.legs[1].timingNote,/10 PM closing/);
  assert.match(t.lines.at(-1).title,/after closing/);
  assert.match(itineraryBriefing(s,t).join(' '),/after the opening begins/);
  const direct = updateState(s,{action:'skip',slot:'breakfast'});
  const first = trackerFor(direct).lines[0];
  assert.equal(new URL(first.url).searchParams.get('travelmode'),'walking');
  assert.equal(new URL(first.url).searchParams.get('destination'),catalog.event.address);
});

test('spoken details apply within the current visit and absence of a work conflict suppresses that alert', () => {
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
  let original = choose(start(),'transit','taxi');
  for (const slot of [...meals,'nightlife']) original = choose(original,slot,catalog[slot][0].id);
  original = choose(choose(original,'toDinner','muni'),'toNightlife','muni');
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
    // This breakfast requires a second taxi. Dropping it removes that fare too.
    // This evening uses one Muni fare even when the dinner stop is skipped.
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
test('dinner and travel choices update the invitation preview and the API rejects delivery',async () => {
  const app = await listen(':memory:');
  try {
    const api = app.url+'/api/demo';
    const initial = await fetch(api);
    const headers = {'X-Atmos-Visit':initial.headers.get('x-atmos-visit')};
    const preview = await initial.json();
    assert.deepEqual(preview.tracker.legs,[]);
    assert.deepEqual(preview.catalog.toDinner,[]);
    assert.equal(preview.dinnerTextDraft,null);
    const submit = action => post(api,action,headers);
    await submit({action:'start',transcript:intro});
    const pm = await (await submit({action:'choose',slot:'dinner',id:'dinner-lataqueria'})).json();
    const walking = await (await submit({action:'choose',slot:'toDinner',id:'walk',revision:pm.state.revision})).json();
    assert.equal(walking.dinnerTextDraft.time,walking.tracker.legs[0].arrivesAt);
    assert.notEqual(pm.dinnerTextDraft.time,walking.dinnerTextDraft.time);
    assert.ok(walking.dinnerTextDraft.body.includes(walking.dinnerTextDraft.address));
    assert.deepEqual(walking.dinnerTextDraft.recipients,['Gio L.','Andrew S.']);
    assert.equal((await submit({action:'sendDinnerText',key:'legacy-draft'})).status,400);
    await submit({action:'choose',slot:'nightlife',id:'game-night'});
    const taxi = await (await submit({action:'choose',slot:'toNightlife',id:'taxi'})).json();
    assert.deepEqual(taxi.dinnerTextDraft,walking.dinnerTextDraft);
    assert.equal((await submit({action:'sendDinnerText'})).status,400);
    assert.deepEqual(taxi.state.invitations,[]);
    const recalled = await (await post(app.url+'/api/recall',{scope:'private',query:'travel'},headers)).json();
    assert.ok(recalled.results.includes('Travel to dinner: Walk'));
    assert.ok(recalled.results.includes('Travel to nightlife: City taxi'));
  } finally { await app.close(); }
});

test('only explicit catalog selections confirm itinerary sections, including the fixed hackathon',async () => {
  const app = await listen(':memory:');
  try {
    const api = app.url+'/api/demo';
    const initial = await fetch(api);
    const headers = {'X-Atmos-Visit':initial.headers.get('x-atmos-visit')};
    const read = async () => (await fetch(api,{headers})).json();
    const submit = action => post(api,action,headers);
    assert.deepEqual((await initial.json()).state.confirmedSlots,[]);
    const started = await (await submit({action:'start',transcript:intro})).json();
    assert.deepEqual(started.state.confirmedSlots,[]);
    assert.equal((await submit({action:'choose',slot:'event',id:'unlisted-event'})).status,400);
    assert.deepEqual((await read()).state,started.state);

    const eventChoice = {action:'choose',slot:'event',id:catalog.event.id};
    const confirmed = await (await submit({...eventChoice,revision:started.state.revision})).json();
    assert.deepEqual(started.tracker.lines,[]);
    assert.ok(confirmed.tracker.lines.some(line=>line.title.includes('opening remarks')));
    assert.equal(confirmed.state.choices.event,catalog.event.id);
    assert.deepEqual(confirmed.state.confirmedSlots,['event']);
    assert.deepEqual(confirmed.catalog.event,started.catalog.event);
    assert.equal((await submit({...eventChoice,revision:started.state.revision})).status,409);
    const reselected = await (await submit({...eventChoice,revision:confirmed.state.revision})).json();
    assert.deepEqual(reselected.state.confirmedSlots,['event']);
    assert.deepEqual(reselected.tracker,confirmed.tracker);
    const recall = await post(app.url+'/api/recall',{scope:'private',query:'event'},headers);
    assert.ok((await recall.json()).results.includes('event: '+catalog.event.title));

    const expected = ['event'];
    for (const slot of ['transit','breakfast','lunch','dinner','nightlife']) {
      const before = await read();
      const option = catalog[slot].find(o=>o.available!==false && o.id!==before.state.choices[slot]);
      assert.ok(option);
      const response = await submit({action:'choose',slot,id:option.id,revision:before.state.revision});
      assert.equal(response.status,200);
      expected.push(slot);
      const after = await response.json();
      assert.equal(after.state.choices[slot],option.id);
      assert.deepEqual(after.state.confirmedSlots,expected);
      assert.deepEqual((await read()).state,after.state);
    }
    const reset = await (await submit({action:'reset'})).json();
    assert.deepEqual(reset.state.confirmedSlots,[]);
    assert.deepEqual(reset.state.choices,{});
  } finally { await app.close(); }
});

test('each page starts empty, while concurrent pages keep independent active choices',async () => {
  const app = await listen(':memory:');
  try {
    const api = app.url+'/api/demo';
    const legacyCookie = {Cookie:'atmos_visit='+'a'.repeat(64)};
    const first = await fetch(api,{headers:legacyCookie});
    assert.equal(first.headers.get('set-cookie'),null);
    const headers = {'X-Atmos-Visit':first.headers.get('x-atmos-visit')};
    const built = await (await post(api,{action:'start',transcript:intro},headers)).json();
    assert.deepEqual(built.state.choices,{});
    assert.deepEqual(built.state.confirmedSlots,[]);
    assert.equal(built.dinnerTextDraft,null);
    assert.deepEqual(built.tracker,{lines:[],legs:[],cost:0,spent:0,steps:0,calories:0});
    assert.equal(built.state.profile.discretion,true);
    assert.ok(!Object.hasOwn(built.state,'transcript'));
    const submit = action => post(api,action,headers);
    await submit({action:'choose',slot:'dinner',id:catalog.dinner[0].id});
    const recall = async (scope,query,h={}) => (await post(app.url+'/api/recall',{scope,query},h)).json();
    assert.ok((await recall('private','boss',headers)).results.some(f=>f.includes('sick')));
    assert.equal((await recall('private','boss')).results.length,0);
    assert.equal((await recall('shared','boss',headers)).results.length,0);
    assert.ok((await recall('shared','tofu')).results.some(f=>f.includes('Proper Food')));
    const second = await post(api,{action:'begin'},legacyCookie);
    assert.notEqual(second.headers.get('x-atmos-visit'),headers['X-Atmos-Visit']);
    const fresh = await second.json();
    assert.deepEqual(fresh.state.choices,{});
    assert.deepEqual(fresh.state.invitations,[]);
    assert.deepEqual(fresh.state.skippedSlots,[]);
    assert.equal(fresh.dinnerTextDraft,null);
    assert.equal(fresh.state.profile.workplaceNote,undefined);
    const original = await (await fetch(api,{headers})).json();
    assert.equal(original.state.choices.dinner,catalog.dinner[0].id);
    assert.deepEqual(original.state.invitations,[]);
    assert.equal((await submit({action:'reset',revision:0})).status,409);
    const skipped = await (await submit({action:'skip',slot:'dinner'})).json();
    assert.equal(skipped.dinnerTextDraft,null);
  } finally { await app.close(); }
});

test('browser and single-use native briefings never enter SQLite or survive a restart',async () => {
  const dir = await mkdtemp(join(tmpdir(),'atmos-trip-test-'));
  const filename = join(dir,'test.sqlite');
  let app = await listen(filename);
  try {
    const marker = 'private-native-browser-marker';
    const transcript = 'Visiting Richmond SF from Singapore with a budget of $71342. '+marker;
    const first = await post(app.url+'/api/demo',{action:'start',transcript});
    const headers = {'X-Atmos-Visit':first.headers.get('x-atmos-visit')};
    const profile = (await first.json()).state.profile;
    assert.equal(profile.budget,71342);
    await post(app.url+'/api/demo',{action:'choose',slot:'lunch',id:catalog.lunch[0].id},headers);
    const native = await post(app.url+'/api/handoff',{transcript},{'X-Atmos-Client':'native-demo'});
    assert.equal(native.status,201);
    const {ticket} = await native.json();
    const handoff = await fetch(app.url+'/handoff/'+ticket,{redirect:'manual'});
    assert.equal(handoff.status,303);
    const location = handoff.headers.get('location');
    assert.match(location,/^\/#planning=[0-9a-f]{64}$/);
    assert.equal((await fetch(app.url+'/handoff/'+ticket)).status,410);
    const claim = {action:'handoff',ticket:location.split('=')[1]};
    const active = await (await post(app.url+'/api/demo',claim)).json();
    assert.deepEqual(active.state.profile,profile);
    assert.ok(!JSON.stringify(active).includes(marker));
    assert.deepEqual(active.state.choices,{});
    assert.equal((await post(app.url+'/api/demo',claim)).status,410);
    await app.close(); app = await listen(filename);
    assert.equal((await fetch(app.url+'/api/demo',{headers})).status,410);
    const other = await (await fetch(app.url+'/api/demo')).json();
    assert.deepEqual(other.state,newState());
    const db = new DatabaseSync(filename,{readOnly:true});
    try {
      assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_schema WHERE name IN ('visitors','handoffs')").get().n,0);
      assert.equal(db.prepare('SELECT count(*) AS n FROM test_memory_jobs').get().n,0);
    } finally { db.close(); }
    const file = await readFile(filename);
    assert.ok(!file.includes(marker) && !file.includes('71342'));
  } finally { await app.close(); await rm(dir,{recursive:true,force:true}); }
});

test('a previously valid visitor cookie opens fresh options in an upgraded database',async () => {
  const dir = await mkdtemp(join(tmpdir(),'atmos-legacy-test-'));
  const filename = join(dir,'test.sqlite');
  const cookie = 'a'.repeat(64);
  const db = new DatabaseSync(filename);
  try {
    db.exec('CREATE TABLE visitors (id TEXT PRIMARY KEY,state TEXT NOT NULL)');
    const old = choose(start(),'dinner',catalog.dinner[0].id);
    db.prepare('INSERT INTO visitors VALUES (?,?)').run(createHash('sha256').update(cookie).digest('hex'),
      JSON.stringify({...old,transcript:'private legacy briefing',sentDinnerTexts:[{body:'previous invitation'}]}));
  } finally { db.close(); }
  const app = await listen(filename);
  try {
    const response = await post(app.url+'/api/demo',{action:'begin'},{Cookie:'atmos_visit='+cookie});
    const fresh = await response.json();
    assert.equal(response.status,200);
    assert.deepEqual(fresh.state.choices,{});
    assert.deepEqual(fresh.tracker.lines,[]);
    assert.equal(fresh.dinnerTextDraft,null);
    assert.ok(!JSON.stringify(fresh).includes('private legacy briefing'));
    assert.ok(!JSON.stringify(fresh).includes('previous invitation'));
  } finally { await app.close(); await rm(dir,{recursive:true,force:true}); }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemo } from './server.mjs';
import { catalog, intro, newState, updateState, trackerFor } from './scenario.mjs';

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

async function listen(filename) {
  const server = createDemo({filename});
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  return {url:'http://127.0.0.1:'+server.address().port,close:()=>new Promise(resolve=>server.close(resolve))};
}
const post = (url,data,extra={}) => fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...extra},body:JSON.stringify(data)});
test('browser memories are isolated and survive a restart, native handoffs are single use',async () => {
  const dir = await mkdtemp(join(tmpdir(),'atmos-trip-test-'));
  let app = await listen(join(dir,'test.sqlite'));
  try {
    let res = await fetch(app.url+'/api/demo');
    const cookie = res.headers.get('set-cookie').split(';')[0];
    assert.equal((await res.json()).state.started,false);
    res = await post(app.url+'/api/demo',{action:'start',transcript:intro},{Cookie:cookie});
    assert.equal((await res.json()).state.profile.discretion,true);
    const recall = (scope,query,headers={}) => post(app.url+'/api/recall',{scope,query},headers).then(r=>r.json());
    assert.ok((await recall('private','boss',{Cookie:cookie})).results.some(f=>f.includes('sick')));
    assert.equal((await recall('private','boss')).results.length,0);
    assert.equal((await recall('shared','boss',{Cookie:cookie})).results.length,0);
    assert.ok((await recall('shared','tofu')).results.some(f=>f.includes('Proper Food')));
    let other = await (await fetch(app.url+'/api/demo')).json();
    assert.equal(other.state.transcript,''); assert.equal(other.state.profile.workplaceNote,undefined);
    res = await post(app.url+'/api/demo',{action:'reset',revision:0},{Cookie:cookie});
    assert.equal(res.status,409);
    await app.close(); app = await listen(join(dir,'test.sqlite'));
    const saved = await (await fetch(app.url+'/api/demo',{headers:{Cookie:cookie}})).json();
    assert.equal(saved.state.transcript,intro);
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

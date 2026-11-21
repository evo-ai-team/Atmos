import assert from 'node:assert/strict';
import test from 'node:test';
import {catalog, guideForVisit, intro, newState, trackerFor, updateState} from './scenario.mjs';
import {routeFor, routeMap} from './public/route-map.js';
import {detailsFor} from './public/views.js';

const start = () => updateState(newState(),{action:'start',transcript:intro});
const choose = (s,slot,id) => updateState(s,{action:'choose',slot,id});
const trip = state => ({state,catalog:guideForVisit(catalog,state),tracker:trackerFor(state)});

function assertEndpoints(route) {
  const first=route.segments[0].points[0];
  const last=route.segments.at(-1).points.at(-1);
  for (const [actual,stop] of [[first,route.stops[0]],[last,route.stops.at(-1)]]) {
    assert.ok(Math.hypot(actual[0]-stop.point[0],actual[1]-stop.point[1])<0.08,stop.label);
  }
  for (const segment of route.segments) {
    assert.ok(segment.points.length>=2);
    assert.ok(segment.points.every(([x,y])=>Number.isFinite(x)&&Number.isFinite(y)));
  }
  const html=routeMap(route,360,150);
  assert.doesNotMatch(html,/NaN|Infinity/);
  assert.ok(html.includes('data-replay-path'));
}

test('transport previews draw different paths without changing the saved morning route', () => {
  const state=start();
  const data=trip(state);
  const saved=routeFor(data);
  const paths=new Set();
  for (const {id} of data.catalog.transit) {
    const preview=routeFor(data,'transit',id);
    assertEndpoints(preview);
    paths.add(JSON.stringify(preview.segments.map(s=>s.points)));
    const committed=routeFor(trip(choose(state,'transit',id)));
    assert.deepEqual(committed.segments,preview.segments);
  }
  assert.equal(paths.size,5);
  assert.deepEqual(routeFor(data),saved);
  assert.match(saved.modeLabel,/1 California/);
  const battery=trip(choose(state,'breakfast','breakfast-battery'));
  const downtown=routeFor(battery);
  assert.match(downtown.modeLabel,/38R Geary Rapid/);
  assert.equal(downtown.segments.at(-1).kind,'walk');
  for (const morning of [battery,trip(choose(state,'breakfast','breakfast-proper')),trip(updateState(state,{action:'skip',slot:'breakfast'}))]) {
    if (morning!==battery) assert.deepEqual(routeFor(morning).stops.map(s=>s.key),['home','loft']);
    const paths=morning.catalog.transit.map(({id})=>routeFor(morning,'transit',id).segments.flatMap(s=>s.points));
    assert.equal(new Set(paths.map(p=>JSON.stringify(p))).size,5);
  }
});

test('evening previews use the selected venues, travel mode and origin after a skipped dinner', () => {
  const state=start();
  for (const dinner of [...catalog.dinner.filter(o=>o.available!==false),null]) {
    const evening=dinner ? choose(state,'dinner',dinner.id) : updateState(state,{action:'skip',slot:'dinner'});
    for (const night of catalog.nightlife) {
      const data=trip(choose(evening,'nightlife',night.id));
      for (const slot of ['toDinner','toNightlife']) {
        const effectiveSlot=!dinner && slot==='toDinner' ? 'toNightlife' : slot;
        const options=data.catalog[effectiveSlot];
        const expected=effectiveSlot==='toDinner' ? ['loft',dinner.id] : [dinner?.id ?? 'loft',night.id];
        const paths=new Set();
        for (const {id} of options) {
          const route=routeFor(data,effectiveSlot,id);
          assert.deepEqual(route.stops.map(s=>s.key),expected);
          assert.ok(route.segments.some(s=>s.kind===id));
          assertEndpoints(route);
          paths.add(JSON.stringify(route.segments.flatMap(s=>s.points)));
        }
        assert.equal(paths.size,options.length,expected.join(' → '));
        assert.equal(routeFor(data,slot).mode,data.tracker.legs.find(l=>l.slot===effectiveSlot).id);
      }
    }
  }
});

test('the lunch popup presents both friends’ existing demo posts together', () => {
  const view=detailsFor(trip(start()),'lunchPosts');
  for (const friend of catalog.contacts) {
    assert.ok(view.body.includes(friend.platform));
    assert.ok(view.body.includes(friend.name));
    assert.ok(view.body.includes(friend.caption));
    assert.ok(view.body.includes(friend.place));
  }
  assert.match(view.body,/Back to my trip/);
  assert.doesNotMatch(view.body,/data-approve-text|data-action="reroute"/);
});

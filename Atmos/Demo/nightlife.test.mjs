import assert from 'node:assert/strict';
import test from 'node:test';
import { catalog, intro, newState, trackerFor, updateState } from './scenario.mjs';

const start = (transcript = intro) => updateState(newState(), {action:'start', transcript});
const preview = (state, id) => updateState(state, {action:'previewNightlife', id});
const confirm = (state, id) => updateState(state, {action:'choose', slot:'nightlife', id});

test('only Tech Afterhours previews or direct confirmations can trigger the boss post', () => {
  const state = start();
  for (const option of catalog.nightlife.filter(row => row.id !== 'afterhours')) {
    assert.deepEqual(preview(state,option.id), state);
    assert.equal(confirm(state,option.id).alert, 'idle');
  }
  assert.equal(confirm(state,'afterhours').alert, 'shown');
  assert.throws(() => preview(state,'unknown-venue'), /unavailable/);
});

test('the preview can be dismissed or rerouted and replayed without committing nightlife', () => {
  const original = confirm(start(),'game-night');
  let session = original;
  for (const response of ['dismiss','reroute','dismiss']) {
    const shown = preview(session,'afterhours');
    assert.deepEqual(shown, {...session, alert:'shown', revision:session.revision+1});
    assert.deepEqual(trackerFor(shown), trackerFor(session));
    assert.deepEqual(preview(shown,'afterhours'), shown);
    const resolved = updateState(shown,{action:response});
    assert.equal(resolved.choices.nightlife,'game-night');
    assert.equal(resolved.alert, response === 'reroute' ? 'rerouted' : 'dismissed');
    assert.deepEqual(preview(resolved,'westend'),resolved);
    assert.equal(confirm(resolved,'afterhours').alert, resolved.alert);
    session = resolved;
  }
  assert.equal(original.alert,'idle');
  const confirmed = confirm(session,'afterhours');
  assert.equal(confirmed.choices.nightlife,'afterhours');
  assert.equal(preview(confirmed,'afterhours').alert,'shown');
});

test('manual replay remains available for discreet briefings and personal context gates all automatic alerts', () => {
  const state = start();
  const manual = updateState(state,{action:'alert'});
  assert.equal(manual.alert,'shown');
  assert.deepEqual(manual.confirmedSlots,[]);
  const dismissed = updateState(manual,{action:'dismiss'});
  assert.equal(updateState(dismissed,{action:'alert'}).alert,'shown');

  const neutral = start('Help me plan my Richmond SF hackathon visit.');
  assert.deepEqual(preview(neutral,'afterhours'),neutral);
  assert.equal(confirm(neutral,'afterhours').alert,'idle');
  assert.throws(() => updateState(neutral,{action:'alert'}),/no workplace conflict/);
});

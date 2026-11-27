import assert from 'node:assert/strict';
import test from 'node:test';
import {createAutosave} from '../src/autosave.mjs';

function tab() {
  return {
    text: '',
    saved: '',
    get dirty() { return this.text !== this.saved; },
  };
}

test('autosaves each file after its own idle delay', async t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const first = tab();
  const second = tab();
  const writes = [];
  const autosave = createAutosave({write(current) {
    writes.push(current.text);
    current.saved = current.text;
  }});

  first.text = 'f';
  autosave.schedule(first);
  t.mock.timers.tick(600);
  first.text = 'first';
  second.text = 'second';
  autosave.schedule(first);
  t.mock.timers.tick(300);
  autosave.schedule(second);
  t.mock.timers.tick(699);
  assert.deepEqual(writes, []);
  t.mock.timers.tick(1);
  await autosave.idle();
  assert.deepEqual(writes, ['first']);
  t.mock.timers.tick(300);
  await autosave.idle();
  assert.deepEqual(writes, ['first', 'second']);
  autosave.dispose();
});

test('manual save waits for an in-flight autosave and keeps later edits', async t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const current = tab();
  const writes = [];
  const firstWrite = Promise.withResolvers();
  const started = Promise.withResolvers();
  const autosave = createAutosave({async write(tab) {
    const content = tab.text;
    writes.push(content);
    if (writes.length === 1) {
      started.resolve();
      await firstWrite.promise;
    }
    tab.saved = content;
  }});

  current.text = 'first';
  autosave.schedule(current);
  t.mock.timers.tick(1000);
  await started.promise;
  current.text = 'second';
  autosave.schedule(current);
  t.mock.timers.tick(1000);
  const manual = autosave.save(current);
  assert.deepEqual(writes, ['first']);
  firstWrite.resolve();
  await manual;
  await autosave.idle();
  assert.deepEqual(writes, ['first', 'second']);
  assert.equal(current.dirty, false);
  autosave.dispose();
});

test('reports failed saves and clears canceled or disabled timers', async t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const current = tab();
  const failure = new Error('changed on disk');
  const failures = [];
  let attempts = 0;
  const write = () => { attempts++; throw failure; };
  const autosave = createAutosave({write, onError(tab, error) { failures.push({tab, error}); }});
  current.text = 'draft';
  autosave.schedule(current);
  autosave.cancel(current);
  t.mock.timers.tick(1000);
  assert.equal(attempts, 0);
  autosave.schedule(current);
  t.mock.timers.tick(1000);
  await autosave.idle();
  t.mock.timers.tick(5000);
  assert.equal(attempts, 1);
  assert.deepEqual(failures, [{tab: current, error: failure}]);
  await assert.rejects(autosave.save(current), failure);

  autosave.schedule(current);
  autosave.dispose();
  const disabled = createAutosave({delay: null, write});
  disabled.schedule(current);
  t.mock.timers.tick(1000);
  await autosave.idle();
  await disabled.idle();
  assert.equal(attempts, 2);
});

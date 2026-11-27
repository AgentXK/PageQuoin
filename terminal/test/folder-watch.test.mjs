import assert from 'node:assert/strict';
import {existsSync, readdirSync} from 'node:fs';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {setTimeout as delay} from 'node:timers/promises';
import {watchProjectFolder} from '../src/folder-watch.mjs';

async function waitFor(condition) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (condition()) return;
    await delay(25);
  }
  assert.fail('Expected a directory refresh');
}

test('folder watcher refreshes on creation, rename and deletion, and stops when disposed', async t => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'pq-watch-'));
  let entries;
  let refreshes = 0;
  const dispose = watchProjectFolder(folder, () => {
    entries = readdirSync(folder);
    refreshes++;
  });
  t.after(async () => {
    dispose();
    await fs.rm(folder, {recursive: true, force: true});
  });

  await waitFor(() => Array.isArray(entries));
  const created = path.join(folder, 'new.tex');
  const renamed = path.join(folder, 'renamed.tex');
  await fs.writeFile(created, '');
  await waitFor(() => entries.includes('new.tex'));
  await fs.rename(created, renamed);
  await waitFor(() => entries.includes('renamed.tex') && !entries.includes('new.tex'));
  await fs.unlink(renamed);
  await waitFor(() => entries.length === 0);
  dispose();
  const stoppedAt = refreshes;
  await fs.writeFile(created, '');
  await delay(250);
  assert.equal(refreshes, stoppedAt);
});

test('folder watcher polls if the native watcher cannot attach', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pq-watch-fallback-'));
  const folder = path.join(root, 'not-ready');
  let refreshes = 0;
  let found = false;
  const dispose = watchProjectFolder(folder, () => {
    refreshes++;
    found = existsSync(folder) && readdirSync(folder).includes('main.tex');
  });
  t.after(async () => {
    dispose();
    await fs.rm(root, {recursive: true, force: true});
  });

  await waitFor(() => refreshes > 0);
  assert.equal(found, false);
  await fs.mkdir(folder);
  await fs.writeFile(path.join(folder, 'main.tex'), '');
  await waitFor(() => found);
});

import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {listSessions, readMainSelection, readSession, readSessionRemoval, removeSession,
  saveMainSelection, saveSession} from '../src/session.mjs';

test('stores one safe snapshot per project and lists the newest first', async t => {
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-session-'));
  const directory = path.join(scratch, 'records');
  const override = process.env.PAGEQUOIN_STATE_DIR;
  process.env.PAGEQUOIN_STATE_DIR = directory;
  t.after(async () => {
    if (override === undefined) delete process.env.PAGEQUOIN_STATE_DIR;
    else process.env.PAGEQUOIN_STATE_DIR = override;
    await fs.rm(scratch, {recursive: true, force: true});
  });

  let now = 100;
  t.mock.method(Date, 'now', () => now);
  assert.deepEqual(await listSessions(), []);
  const first = {root: path.join(scratch, 'first'), main: 'main.tex', active: 'chapters/é.tex',
    tabs: [{file: 'chapters/é.tex', cursor: 5, top: 0, left: 0, text: 'Never store buffer contents'}],
    pdf: '.pagequoin-terminal/key/main.pdf'};
  const second = {root: path.join(scratch, 'second'), main: null, active: null, tabs: [], pdf: null};
  await saveSession(first);
  now++;
  await saveSession(second);
  now++;
  first.tabs[0].cursor = 17;
  first.tabs[0].wrapStart = 12;
  await saveSession(first);

  const damagedRoot = path.join(scratch, 'damaged');
  const damagedName = createHash('sha256').update(damagedRoot).digest('hex') + '.json';
  const damaged = path.join(directory, damagedName);
  await fs.writeFile(damaged, '{');
  assert.equal((await listSessions()).length, 2);
  await fs.writeFile(damaged, JSON.stringify({...second, root: damagedRoot, version: 1, updatedAt: now + 1, main: '../escape.tex'}));
  const sessions = await listSessions();
  assert.deepEqual(sessions, [
    {...first, tabs: [{file: 'chapters/é.tex', cursor: 17, top: 0, left: 0, wrapStart: 12}], updatedAt: 102},
    {...second, updatedAt: 101},
  ]);
  const entries = await fs.readdir(directory);
  assert.equal(entries.length, 3);
  for (const entry of entries) {
    assert.doesNotMatch(await fs.readFile(path.join(directory, entry), 'utf8'), /Never store buffer contents/);
  }
  await assert.rejects(saveSession({...first, main: '../escape.tex'}), /invalid session/i);
});

test('terminal updates preserve desktop workspace details and share explicit main selection', async t => {
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-shared-session-'));
  const directory = path.join(scratch, 'sessions');
  const root = await fs.realpath(scratch);
  const override = process.env.PAGEQUOIN_STATE_DIR;
  process.env.PAGEQUOIN_STATE_DIR = directory;
  t.after(async () => {
    if (override === undefined) delete process.env.PAGEQUOIN_STATE_DIR;
    else process.env.PAGEQUOIN_STATE_DIR = override;
    await fs.rm(scratch, {recursive: true, force: true});
  });
  const name = createHash('sha256').update(root).digest('hex') + '.json';
  const desktopWorkspace = {layout: 'split', sidebarWidth: 235, sidebarCollapsed: false};
  const desktopPosition = {caretOffset: 6, scrollY: 22, normalizedCaretOffset: 5};
  const media = {file: 'figure.pdf', cursor: 0, top: 0, left: 0, desktopOnly: true};
  const tab = {file: 'chapters/paper.tex', cursor: 5, top: 0, left: 0};
  const project = {root, main: tab.file, active: tab.file, pdf: null, tabs: [tab]};
  await fs.mkdir(directory);
  await fs.writeFile(path.join(directory, name), JSON.stringify({
    ...project, version: 1, updatedAt: 1, desktopWorkspace,
    tabs: [{...tab, desktopPosition}, media],
  }));
  assert.deepEqual((await readSession(root)).tabs[0].desktopPosition, desktopPosition);
  assert.equal(await readMainSelection(root), undefined);
  await saveMainSelection(root, tab.file);
  assert.equal(await readMainSelection(root), tab.file);
  await saveMainSelection(root, null);
  assert.equal(await readMainSelection(root), null);

  await saveSession(project);
  const unchanged = await readSession(root);
  assert.deepEqual(unchanged.desktopWorkspace, desktopWorkspace);
  assert.deepEqual(unchanged.tabs, [{...tab, desktopPosition}, media]);
  await saveSession({...project, tabs: [{...tab, cursor: 8}]});
  assert.deepEqual((await readSession(root)).tabs, [{...tab, cursor: 8}, media]);
});

test('removing a recent project blocks old checkpoints and preserves project contents and settings', async t => {
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-remove-session-'));
  const root = path.join(scratch, 'project');
  const directory = path.join(scratch, 'sessions');
  const override = process.env.PAGEQUOIN_STATE_DIR;
  process.env.PAGEQUOIN_STATE_DIR = directory;
  t.after(async () => {
    if (override === undefined) delete process.env.PAGEQUOIN_STATE_DIR;
    else process.env.PAGEQUOIN_STATE_DIR = override;
    await fs.rm(scratch, {recursive: true, force: true});
  });

  t.mock.method(Date, 'now', () => 123);
  const source = path.join(root, 'paper.tex');
  await fs.mkdir(root);
  await fs.writeFile(source, 'A paper');
  const project = {root, main: 'paper.tex', active: 'paper.tex', pdf: null, tabs: []};
  const other = {...project, root: path.join(scratch, 'other')};
  const removedAtOnOpen = await readSessionRemoval(root);
  await saveSession(project, {removedAtOnOpen});
  await saveSession(other);
  await saveMainSelection(root, project.main);

  await removeSession(root);
  const name = createHash('sha256').update(root).digest('hex') + '.removed.json';
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(directory, name), 'utf8')),
    {version: 1, root, removedAt: 123});
  await saveSession(project, {removedAtOnOpen});
  assert.equal(await readSession(root), null);
  assert.deepEqual((await listSessions()).map(session => session.root), [other.root]);
  assert.equal(await fs.readFile(source, 'utf8'), 'A paper');
  assert.equal(await readMainSelection(root), 'paper.tex');

  const removedAtOnReopen = await readSessionRemoval(root);
  await saveSession(project, {removedAtOnOpen: removedAtOnReopen});
  assert.equal((await readSession(root)).updatedAt, 124);
  assert.equal((await listSessions())[0].root, root);

  await removeSession(root);
  await saveSession(project, {removedAtOnOpen: removedAtOnReopen});
  assert.equal(await readSessionRemoval(root), 124);
  assert.equal(await readSession(root), null);
});

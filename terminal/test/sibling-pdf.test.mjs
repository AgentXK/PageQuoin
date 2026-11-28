import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {compilePDF, readSharedPDF} from '../src/build.mjs';

const engine = process.env.TECTONIC_PATH?.trim() || 'tectonic';
const hasTectonic = spawnSync(engine, ['--version'], {windowsHide: true}).status === 0;
const tex = text => '\\documentclass{article}\n\\begin{document}\n' + text + '\n\\end{document}\n';

async function fixture(t) {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-export-'));
  t.after(() => fs.rm(temp, {recursive: true, force: true}));
  const root = await fs.realpath(temp);
  const chapters = path.join(root, 'chapters and notes');
  await fs.mkdir(chapters);
  const main = path.join(chapters, 'paper draft.tex');
  await fs.writeFile(main, tex('First draft'));
  return {root, main, exported: path.join(chapters, 'paper draft.pdf')};
}

test('build writes and updates only the PDF beside a nested main file', {skip: !hasTectonic}, async t => {
  const {root, main, exported} = await fixture(t);
  const options = {engine};
  assert.equal(await compilePDF(root, main, options), exported);
  assert.equal(await readSharedPDF(root, main), exported);
  const first = await fs.readFile(exported);
  assert.equal(first.subarray(0, 5).toString(), '%PDF-');

  await fs.writeFile(main, tex('The revised draft has a new paragraph.'));
  assert.equal(await compilePDF(root, main, options), exported);
  const revised = await fs.readFile(exported);
  assert.notDeepEqual(revised, first);

  const canceled = new AbortController();
  canceled.abort();
  await assert.rejects(compilePDF(root, main, {...options, signal: canceled.signal}), /Build stopped/);
  await fs.writeFile(main, tex('\\undefinedpagequoincommand'));
  await assert.rejects(compilePDF(root, main, options), /Tectonic failed/);
  assert.deepEqual(await fs.readFile(exported), revised);
  assert.deepEqual(await fs.readdir(root), ['chapters and notes']);
  assert.deepEqual((await fs.readdir(path.dirname(main))).sort(), ['paper draft.pdf', 'paper draft.tex']);
});

test('a blocked sibling output leaves the destination intact without another copy', {skip: !hasTectonic}, async t => {
  const {root, main, exported} = await fixture(t);
  const options = {engine};
  await fs.mkdir(exported);
  const untouched = path.join(exported, 'keep');
  await fs.writeFile(untouched, 'untouched');
  await assert.rejects(compilePDF(root, main, options), /cannot replace a non-regular file/);
  assert.equal(await readSharedPDF(root, main), null);
  assert.equal(await fs.readFile(untouched, 'utf8'), 'untouched');

  if (process.platform !== 'win32') {
    await fs.rm(exported, {recursive: true});
    const target = path.join(root, 'existing.pdf');
    await fs.writeFile(target, 'Keep this link target');
    await fs.symlink(target, exported);
    await assert.rejects(compilePDF(root, main, options), /cannot replace a non-regular file/);
    assert.equal(await fs.readlink(exported), target);
    assert.equal(await fs.readFile(target, 'utf8'), 'Keep this link target');
  }
  await assert.rejects(fs.lstat(path.join(root, '.pagequoin-build')), {code: 'ENOENT'});
  assert.deepEqual((await fs.readdir(path.dirname(main))).sort(), ['paper draft.pdf', 'paper draft.tex']);
});

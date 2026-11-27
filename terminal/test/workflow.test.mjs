import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {cleanBuildIntermediates, compilePDF, createPreview, readSharedPDF} from '../src/build.mjs';
import {EditorBuffer, lineCells, visualColumn} from '../src/editor.mjs';
import {decodeText, encodeText, findMain, newDocument, projectPath, readDocument, saveDocument} from '../src/files.mjs';

async function project(t) {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-terminal-'));
  t.after(() => fs.rm(folder, {recursive: true, force: true}));
  return fs.realpath(folder);
}

test('edits and undoes without splitting composed characters', () => {
  const buffer = new EditorBuffer('main.tex', {text: 'a👩‍🔬é\n短行'});
  buffer.cursor = 'a👩‍🔬'.length;
  buffer.key('', {backspace: true}, 10);
  assert.equal(buffer.text, 'aé\n短行');
  assert.equal(buffer.dirty, true);
  buffer.undo();
  assert.equal(buffer.text, 'a👩‍🔬é\n短行');
  assert.equal(buffer.dirty, false);
  buffer.redo();
  assert.equal(buffer.text, 'aé\n短行');
  assert.equal(buffer.find('短'), true);
  assert.deepEqual(buffer.position, {row: 1, column: 0});
  assert.equal(visualColumn('\t短', 2), 6);
  assert.deepEqual(lineCells('短A', 0, 1, 2).map(cell => cell.text), [' ', 'A']);
  buffer.undo();
  buffer.restorePosition({cursor: 2, top: 10, left: 0});
  assert.deepEqual(buffer.position, {row: 0, column: 1});
  assert.equal(buffer.top, 0);
  buffer.restorePosition({cursor: 100, top: 1, left: 0});
  assert.equal(buffer.cursor, buffer.text.length);
});

test('places the caret using rendered cells without splitting graphemes', () => {
  const buffer = new EditorBuffer('main.tex', {text: 'abc\n\t短👩‍🔬e\u0301\x1bZ\nend'});
  for (const [cell, column] of [[-3, 0], [3, 0], [4, 1], [5, 1], [6, 2], [7, 2], [8, 7], [9, 9], [10, 10], [40, 11]]) {
    buffer.placeCursor(1, cell);
    assert.deepEqual(buffer.position, {row: 1, column});
  }
  buffer.placeCursor(0, 2);
  assert.deepEqual(buffer.position, {row: 0, column: 2});
  buffer.moveVertical(1);
  buffer.placeCursor(1, 4);
  buffer.moveVertical(1);
  assert.deepEqual(buffer.position, {row: 2, column: 1});
  buffer.placeCursor(5, 0);
  assert.equal(buffer.cursor, buffer.text.length);
});

test('preserves encoding and line endings and refuses to overwrite changed files', async t => {
  const root = await project(t);
  const format = {encoding: 'utf16be', eol: '\r\n', prefix: Buffer.from([0xfe, 0xff])};
  const file = path.join(root, 'chapter.tex');
  const original = encodeText('第一行\n第二行\n', format);
  await fs.writeFile(file, original);
  const initial = await readDocument(file);
  assert.equal(initial.text, '第一行\n第二行\n');
  const changed = await saveDocument(root, file, '第一行\nChanged\n', initial);
  assert.deepEqual(await fs.readFile(file), encodeText('第一行\nChanged\n', format));
  await fs.writeFile(file, 'external');
  await assert.rejects(saveDocument(root, file, 'mine', changed), /changed on disk/i);
  assert.equal(await fs.readFile(file, 'utf8'), 'external');
  await assert.rejects(newDocument(root, 'chapter.tex'), {code: 'EEXIST'});
  await assert.rejects(projectPath(root, '../elsewhere'), /inside this project/);
  assert.throws(() => decodeText(Buffer.from([1, 0, 3])), /binary/);
  for (const {text, eol, mixed} of [
    {text: 'a\nb\r\n', eol: '\n', mixed: true},
    {text: 'a\rb\r\n', eol: '\r', mixed: true},
    {text: 'a\r\nb\n', eol: '\r\n', mixed: true},
    {text: 'a\r\nb\r', eol: '\r\n', mixed: true},
    {text: 'a\r\nb\r\n', eol: '\r\n', mixed: false},
  ]) {
    const document = decodeText(Buffer.from(text));
    assert.equal(document.eol, eol);
    assert.equal(document.mixedEndings, mixed);
  }
});

test('opens, detects and saves a large TeX source', async t => {
  const root = await project(t);
  const text = '\\documentclass{article}\n' + ('% ' + 'x'.repeat(372) + '\n').repeat(30_000);
  const file = await newDocument(root, 'manuscript.tex', text);
  assert.equal(await findMain(root), file);

  const snapshot = await readDocument(file);
  assert.equal(snapshot.text, text);
  const updated = await saveDocument(root, file, snapshot.text + '% edited\n', snapshot);
  assert.equal((await readDocument(file)).text, updated.text);

  await fs.truncate(file, 33 * 1024 * 1024);
  await assert.rejects(readDocument(file), /manuscript\.tex is 33\.0 MiB.*limit is 32 MiB/);
});

test('only serves the selected PDF on a private loopback URL', async t => {
  const root = await project(t);
  const file = await newDocument(root, 'test.pdf', '%PDF-1.5\nfixture\n');
  const other = await newDocument(root, 'updated.pdf', '%PDF-1.5\nupdated\n');
  const preview = createPreview();
  t.after(() => preview.close());
  const url = await preview.url(file);
  assert.equal(new URL(url).hostname, '127.0.0.1');
  const response = await fetch(url);
  assert.equal(response.headers.get('content-type'), 'application/pdf');
  assert.equal(await response.text(), '%PDF-1.5\nfixture\n');
  assert.equal((await fetch(new URL('/test.pdf', url))).status, 404);
  assert.equal((await fetch(url, {method: 'POST'})).status, 404);
  assert.equal(await preview.url(other), url);
  assert.equal(await (await fetch(url)).text(), '%PDF-1.5\nupdated\n');
});

test('reads only valid previews from a desktop-owned project build directory', async t => {
  const root = await project(t);
  const main = await newDocument(root, 'main.tex', '');
  const folder = path.join(root, '.pagequoin-build');
  const previews = path.join(folder, 'previews');
  const key = createHash('sha256').update('main.tex').digest('hex').slice(0, 16);
  const file = path.join(previews, key + '.pdf');
  await fs.mkdir(previews, {recursive: true});
  await fs.writeFile(file, '%PDF-1.5\nfixture');
  assert.equal(await readSharedPDF(root, main), null);
  await assert.rejects(compilePDF(root, main, {engine: 'engine-not-required'}), /does not own the folder/);
  assert.deepEqual(await fs.readdir(folder), ['previews']);

  await fs.writeFile(path.join(folder, '.pagequoin-owned'), 'PageQuoin Build Artifacts v1\n');
  assert.equal(await readSharedPDF(root, main), file);
  await fs.writeFile(file, 'Not a PDF');
  assert.equal(await readSharedPDF(root, main), null);

  if (process.platform !== 'win32') {
    const target = await newDocument(root, 'elsewhere.pdf', '%PDF-1.5\nfixture');
    await fs.unlink(file);
    await fs.symlink(target, file);
    assert.equal(await readSharedPDF(root, main), null);
  }
});

test('cleans only completed build intermediates and retains project files and PDF previews', async t => {
  const root = await project(t);
  const storage = path.join(root, '.pagequoin-build');
  const finished = '论文-abcdef0123456789';
  const file = relative => path.join(storage, relative);
  async function write(relative, content) {
    const target = file(relative);
    await fs.mkdir(path.dirname(target), {recursive: true});
    await fs.writeFile(target, content);
  }
  await write('.pagequoin-owned', 'PageQuoin Build Artifacts v1\n');
  await write(finished + '/tectonic-output.log', 'published log');
  await write(finished + '/texput.aux', 'published aux');
  await write(finished + '/texput.synctex.gz', 'published source map');
  await write(finished + '/texput.PDF', '%PDF-1.5\nproduced');
  await write(finished + '/chapters/part.aux', 'nested chapter aux');
  await write(finished + '/chapters/appendix/part.log', 'nested appendix log');
  await write(finished + '/chapters/part.pdf', '%PDF-1.5\nnested');
  await write('previews/abcdef0123456789.pdf', '%PDF-1.5\nshared');
  await write('.terminal-run-live/texput.aux', 'active terminal');
  await write('.incoming-0000000000000000/tectonic-output.log', 'active desktop');
  await write('unowned-abcdef0123456789/texput.aux', 'unowned directory');
  const main = await newDocument(root, 'main.tex', 'source text');
  const sourceAux = await newDocument(root, 'main.aux', 'outside build cache');
  if (process.platform !== 'win32') {
    await fs.symlink(sourceAux, file(finished + '/linked.aux'));
    await fs.symlink(sourceAux, file(finished + '/chapters/linked.aux'));
    const elsewhere = path.join(root, 'external');
    await fs.mkdir(elsewhere);
    await fs.writeFile(path.join(elsewhere, 'tectonic-output.log'), 'external file');
    await fs.symlink(elsewhere, file('linked-abcdef0123456789'));
    await fs.symlink(elsewhere, file(finished + '/chapters/linked'));
  }

  assert.equal(await cleanBuildIntermediates(root), 5);
  assert.equal(await cleanBuildIntermediates(root), 0);
  const remaining = process.platform === 'win32' ? ['chapters', 'texput.PDF'] : ['chapters', 'linked.aux', 'texput.PDF'];
  assert.deepEqual((await fs.readdir(file(finished))).sort(), remaining);
  const chapters = process.platform === 'win32' ? ['appendix', 'part.pdf'] : ['appendix', 'linked', 'linked.aux', 'part.pdf'];
  assert.deepEqual((await fs.readdir(file(finished + '/chapters'))).sort(), chapters);
  assert.deepEqual(await fs.readdir(file(finished + '/chapters/appendix')), []);
  assert.equal(await fs.readFile(file(finished + '/chapters/part.pdf'), 'utf8'), '%PDF-1.5\nnested');
  assert.equal(await fs.readFile(main, 'utf8'), 'source text');
  assert.equal(await fs.readFile(sourceAux, 'utf8'), 'outside build cache');
  assert.equal(await fs.readFile(file('previews/abcdef0123456789.pdf'), 'utf8'), '%PDF-1.5\nshared');
  assert.equal(await fs.readFile(file('.terminal-run-live/texput.aux'), 'utf8'), 'active terminal');
  assert.equal(await fs.readFile(file('.incoming-0000000000000000/tectonic-output.log'), 'utf8'), 'active desktop');
  assert.equal(await fs.readFile(file('unowned-abcdef0123456789/texput.aux'), 'utf8'), 'unowned directory');
  if (process.platform !== 'win32') {
    assert.equal(await fs.readFile(file('linked-abcdef0123456789/tectonic-output.log'), 'utf8'), 'external file');
  }
});

test('handles a missing build directory and refuses to clean a directory without ownership', async t => {
  const root = await project(t);
  assert.equal(await cleanBuildIntermediates(root), 0);
  const folder = path.join(root, '.pagequoin-build', 'main-abcdef0123456789');
  await fs.mkdir(folder, {recursive: true});
  const log = path.join(folder, 'tectonic-output.log');
  await fs.writeFile(log, 'keep');
  await assert.rejects(cleanBuildIntermediates(root), /does not own the folder/);
  assert.equal(await fs.readFile(log, 'utf8'), 'keep');
});

test('Tectonic resolves a subfile and a failed rebuild preserves the last PDF', async t => {
  const engine = process.env.TECTONIC_PATH || 'tectonic';
  if (spawnSync(engine, ['--version'], {windowsHide: true}).error) return t.skip('Tectonic unavailable');
  const root = await project(t);
  await fs.mkdir(path.join(root, 'paper with spaces'));
  const file = await newDocument(root, path.join('paper with spaces', 'main.tex'),
    '\\documentclass{article}\n\\begin{document}\n\\input{chapter}\n\\end{document}\n');
  await newDocument(root, path.join('paper with spaces', 'chapter.tex'), 'Terminal preview');
  assert.equal(await findMain(root, file), file);
  assert.equal(await readSharedPDF(root, file), null);
  const pdf = await compilePDF(root, file, {engine});
  const cache = path.join(root, '.pagequoin-build');
  const hash = createHash('sha256').update('paper with spaces/main.tex').digest('hex').slice(0, 16);
  assert.equal(pdf, path.join(cache, 'previews', hash + '.pdf'));
  assert.equal(await fs.readFile(path.join(cache, '.pagequoin-owned'), 'utf8'), 'PageQuoin Build Artifacts v1\n');
  assert.equal(await readSharedPDF(root, file), pdf);
  const content = await fs.readFile(pdf);
  assert.equal(content.subarray(0, 5).toString(), '%PDF-');
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(compilePDF(root, file, {engine, signal: controller.signal}), /stopped/i);
  await fs.writeFile(file, '\\undefinedpagequoincommand\n');
  await assert.rejects(compilePDF(root, file, {engine}), /Tectonic failed/);
  assert.deepEqual(await fs.readFile(pdf), content);
  assert.equal(await readSharedPDF(root, file), pdf);
  assert.deepEqual((await fs.readdir(cache)).sort(), ['.pagequoin-owned', 'previews']);
});

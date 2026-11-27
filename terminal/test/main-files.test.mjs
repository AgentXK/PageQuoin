import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {listTeXFiles} from '../src/files.mjs';

test('lists top-level and nested TeX candidates without following symlinks', async t => {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-main-files-')));
  t.after(() => fs.rm(root, {recursive: true, force: true}));

  for (const directory of ['appendices', 'chapters/detail', '.hidden', 'node_modules/dependency']) {
    await fs.mkdir(path.join(root, directory), {recursive: true});
  }
  for (const file of [
    'report10.tex', 'report2.LTX', 'readme.md', '.ignored.tex', '.hidden/paper.tex',
    'appendices/notes.tex', 'chapters/detail/chapter10.tex', 'chapters/detail/chapter2.tex',
    'node_modules/dependency/docs.tex',
  ]) {
    await fs.writeFile(path.join(root, file), Buffer.from([0]));
  }
  await fs.symlink(path.join(root, 'chapters'), path.join(root, 'linked-directory'), 'junction');
  if (process.platform !== 'win32') {
    await fs.symlink(path.join(root, 'report10.tex'), path.join(root, 'linked-file.tex'));
  }

  assert.deepEqual(await listTeXFiles(root), [
    'report2.LTX', 'report10.tex', 'appendices/notes.tex',
    'chapters/detail/chapter2.tex', 'chapters/detail/chapter10.tex',
  ].map(file => path.join(root, file)));
});

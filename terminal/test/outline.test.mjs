import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, realpath, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {buildOutline} from '../src/outline.mjs';

test('outlines TeX headings at their source positions, including unsaved chapters', async t => {
  const temp = await realpath(await mkdtemp(path.join(os.tmpdir(), 'pagequoin-outline-')));
  t.after(() => rm(temp, {recursive: true, force: true}));
  const root = path.join(temp, 'project');
  await mkdir(path.join(root, 'chapters'), {recursive: true});

  const main = path.join(root, 'main.tex');
  const chapter = path.join(root, 'chapters', 'results.tex');
  const appendix = path.join(root, 'chapters', 'appendix.tex');
  await writeFile(main, String.raw`\documentclass{book}
\section{Preamble}
\begin{document}
% \section{Ignored}
\chapter[Short]{Methods \& \emph{Data}}
\input{chapters/results}
\begin{verbatim}
\section{Literal}
\end{verbatim}
\verb|\section{Inline literal}|
\section* % a comment
[Optional {const ] text}] {After \% and~
before}
\input{../outside}
\input{missing}
\end{document}
\section{After the document}
`);
  await writeFile(chapter, String.raw`\section{Old}`);
  await writeFile(appendix, String.raw`\paragraph{Notes}`);
  await writeFile(path.join(temp, 'outside.tex'), String.raw`\chapter{Outside}`);
  const open = new Map([[chapter, String.raw`\section{Live results}
\include{main}
\input "appendix"
\subsection{子章节}`]]);

  assert.deepEqual(await buildOutline(root, main, open), [
    {file: main, line: 4, level: 1, title: 'Methods & Data'},
    {file: chapter, line: 0, level: 2, title: 'Live results'},
    {file: appendix, line: 0, level: 5, title: 'Notes'},
    {file: chapter, line: 3, level: 3, title: '子章节'},
    {file: main, line: 10, level: 2, title: 'After % and before'},
  ]);
  assert.deepEqual(await buildOutline(root, null), []);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {stripVTControlCharacters} from 'node:util';
import React from 'react';
import {Box, renderToString, Text} from 'ink';
import {BuildLogPopup, CompletionPopup, completionLayout, floatingLayout, MainFilePopup} from '../src/popups.mjs';

const h = React.createElement;

test('floating frames keep the workspace partially visible and fit narrow terminals', () => {
  for (const [columns, height] of [[120, 28], [50, 9], [27, 6], [20, 4]]) {
    const {main, log} = floatingLayout(columns, height, columns - 1);
    for (const frame of [main, log]) {
      assert.ok(frame.left >= 0 && frame.left + frame.width <= columns);
      assert.ok(frame.top >= 0 && frame.top + frame.height <= height);
      assert.ok(frame.width < columns || frame.height < height);
      assert.ok(frame.rows >= 1);
    }
    assert.equal(main.height, main.rows + 3 + Number(main.showFilter) + Number(main.showHint));
    assert.equal(log.height, log.rows + 3);
  }
});

test('Ink paints floating panels above the workspace without consuming layout rows', () => {
  const columns = 82;
  const height = 20;
  const {main, log} = floatingLayout(columns, height, 11);
  const backdrop = Array.from({length: height}, (_, key) => h(Text, {key}, 'x'.repeat(columns)));
  const picker = {offset: 0, selected: 0, activeFile: null, query: ''};
  const output = renderToString(h(Box, {width: columns, height, position: 'relative', flexDirection: 'column'},
    ...backdrop,
    h(BuildLogPopup, {frame: log, lines: [], focused: false}),
    h(MainFilePopup, {frame: main, picker, options: [{file: null, text: 'Automatic'}]})), {columns});
  const lines = stripVTControlCharacters(output).split('\n');

  assert.equal(lines.length, height);
  assert.match(lines[main.top + 1], /^x+│ MAIN DOCUMENT .*× │x+$/);
  assert.match(lines[main.top + 2 + Number(main.showFilter)], /› ✓ Automatic/);
  const mainBody = lines[main.top + 4].slice(main.left + 1, main.left + main.width - 1);
  assert.equal(mainBody, ' '.repeat(main.width - 2));
  assert.equal(lines.at(-1), 'x'.repeat(columns));
  assert.equal(lines[log.top + log.height - 1][log.left], '╰');
});

test('completion opens by the cursor and keeps the selected candidate visible near edges', () => {
  const items = ['section', 'subsection', 'subsubsection', 'subparagraph'].map(label => ({label}));
  const below = completionLayout({columns: 80, height: 24, cursorX: 25, cursorY: 4, items, index: 0});
  assert.equal(below.left + 1, 25);
  assert.equal(below.top, 5);
  assert.equal(below.rows, items.length);

  const above = completionLayout({columns: 16, height: 8, cursorX: 15, cursorY: 5, items, index: 3});
  assert.equal(above.left + above.width, 16);
  assert.equal(above.top + above.height, 5);
  assert.equal(above.rows, 3);
  assert.equal(above.offset, 1);
  assert.equal(completionLayout({columns: 20, height: 5, cursorX: 10, cursorY: 2, items, index: 0}), null);
});

test('shows at most six completion rows and advances the visible range past the sixth match', () => {
  const items = Array.from({length: 22}, (_, index) => ({label: 'candidate ' + index}));
  const screen = {columns: 80, height: 24, cursorX: 25, cursorY: 14, items};
  const first = completionLayout({...screen, index: 0});
  assert.equal(first.top, screen.cursorY + 1);
  assert.equal(first.rows, 6);
  assert.equal(first.offset, 0);

  const scrolled = completionLayout({...screen, index: 6});
  assert.equal(scrolled.rows, 6);
  assert.equal(scrolled.offset, 1);
  assert.equal(items[scrolled.offset + scrolled.rows - 1].label, 'candidate 6');
});

test('the completion popup covers underlying text without moving the source rows', () => {
  const columns = 40;
  const height = 10;
  const cursorY = 2;
  const items = [{label: '\\section'}, {label: '\\subsection'}];
  const frame = completionLayout({columns, height, cursorX: 16, cursorY, items, index: 1});
  const backdrop = Array.from({length: height}, (_, key) => h(Text, {key}, 'x'.repeat(columns)));
  const output = renderToString(h(Box, {width: columns, height, position: 'relative', flexDirection: 'column'},
    ...backdrop, h(CompletionPopup, {frame, items, index: 1})), {columns});
  const lines = stripVTControlCharacters(output).split('\n');

  assert.equal(lines.length, height);
  assert.equal(lines[cursorY], 'x'.repeat(columns));
  assert.match(lines[frame.top + 1], /^x+│ \\section +│x+$/);
  assert.match(lines[frame.top + 2], /^x+│ \\subsection +│x+$/);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {lineCells} from '../src/editor.mjs';
import {WrappedLines} from '../src/wrap.mjs';

const wrap = (width, ...texts) => new WrappedLines(texts.map(text => ({text})), width);

test('maps logical lines to screen rows and gives an exact-fill caret its own row', () => {
  const layout = wrap(4, 'abcdefgh', 'abc', '');
  const first = {row: 0, part: 0, start: 0, end: 4, left: 0, right: 4};
  const second = {row: 0, part: 1, start: 4, end: 8, left: 4, right: 8};
  const atEnd = {row: 0, part: 2, start: 8, end: 8, left: 8, right: 8};
  const nextLine = {row: 1, part: 0, start: 0, end: 3, left: 0, right: 3};
  assert.deepEqual(layout.rowAt(0, 3), first);
  assert.deepEqual(layout.rowAt(0, 4), second);
  assert.deepEqual(layout.rowAt(0, 8), atEnd);
  assert.deepEqual(layout.page(first, 4), [first, second, atEnd, nextLine]);
  assert.deepEqual(layout.advance(first, 3), nextLine);
  assert.deepEqual(layout.advance(nextLine, -1), atEnd);
  assert.deepEqual(layout.advance(nextLine, -20), first);
  assert.equal(layout.advance(first, 20).row, 2);
  assert.equal(layout.columnAt(first, 99), 3);
  assert.equal(layout.columnAt(nextLine, 99), 3);
});

test('wrap segments preserve glyph and tab boundaries and match rendered cells', () => {
  const text = 'a界\t👍🏽z';
  const layout = wrap(4, text, 'abc界z');
  const [leading, trailing, short, carried] = layout.page({row: 0}, 4);
  assert.deepEqual([leading.start, leading.end, leading.left, leading.right], [0, 3, 0, 4]);
  assert.deepEqual([trailing.start, trailing.end, trailing.left, trailing.right], [3, 8, 4, 7]);
  assert.deepEqual([short.start, short.end, short.left, short.right], [0, 3, 0, 3]);
  assert.deepEqual([carried.start, carried.end, carried.left, carried.right], [3, 5, 3, 6]);
  assert.equal(layout.columnAt(leading, 2), 1);
  assert.equal(layout.columnAt(leading, 3), 2);
  assert.equal(layout.columnAt(trailing, 1), 3);
  assert.equal(layout.columnAt(trailing, 2), 7);
  assert.equal(layout.columnAt(short, 3), 2);
  assert.equal(layout.cellAt(trailing, 4), 0);
  assert.equal(layout.cellAt(trailing, 7), 2);
  for (const [part, expected] of [[leading, 'a界 '], [trailing, '👍🏽z']]) {
    const visible = lineCells(text, -1, part.left, part.right - part.left, undefined, part)
      .map(cell => cell.text).join('');
    assert.equal(visible, expected);
  }
});

test('a tab or wide glyph larger than the pane still advances wrap positions', () => {
  const layout = wrap(1, '\t界');
  const [tab, word, atEnd] = layout.page({row: 0}, 5);
  assert.deepEqual([tab.left, tab.right], [0, 4]);
  assert.deepEqual([word.left, word.right], [4, 6]);
  assert.deepEqual([atEnd.left, atEnd.right], [6, 6]);
  assert.equal(layout.columnAt(tab, 0), 0);
  assert.equal(layout.columnAt(word, 0), 1);
  assert.equal(layout.columnAt(atEnd, 0), 2);
  assert.deepEqual(layout.rowAt(0, 2), atEnd);
});

test('wraps at separators and divides an oversized word only when it must', () => {
  const text = 'sea waves source therefore wavesource over';
  const layout = wrap(9, text);
  const rows = layout.page({row: 0}, 20);
  assert.deepEqual(rows.map(({start, end}) => text.slice(start, end)), [
    'sea waves ', 'source ', 'therefore ', 'wavesourc', 'e over',
  ]);
  assert.deepEqual(layout.rowAt(0, 10), rows[1]);
  assert.deepEqual(layout.advance(rows[2], 1), rows[3]);
  assert.equal(layout.columnAt(rows[0], 9), 8);
});

test('keeps a separator after a full-width word without splitting the next word', () => {
  const ascii = 'hello world';
  const mixed = 'word\t猫 dog';
  const asciiLayout = wrap(5, ascii);
  const mixedLayout = wrap(4, mixed);
  assert.deepEqual(asciiLayout.page({row: 0}, 10).map(({start, end}) => ascii.slice(start, end)), [
    'hello ', 'world', '',
  ]);
  assert.deepEqual(mixedLayout.page({row: 0}, 10).map(({start, end}) => mixed.slice(start, end)), [
    'word\t', '猫 ', 'dog',
  ]);
  assert.equal(asciiLayout.cellAt(asciiLayout.rowAt(0, 5), 5), 5);
  assert.deepEqual(mixedLayout.rowAt(0, 5), mixedLayout.segment({row: 0, part: 1}));
});

test('uses the rest of a row before splitting a word that needs multiple rows', () => {
  for (const [text, expected] of [
    ['% abcdefghijk post', ['% abc', 'defgh', 'ijk ', 'post']],
    ['猫 abcdefghijk post', ['猫 ab', 'cdefg', 'hijk ', 'post']],
  ]) {
    const rows = wrap(5, text).page({row: 0}, 20);
    assert.deepEqual(rows.map(({start, end}) => text.slice(start, end)), expected);
  }
});

test('indexes screen rows including soft wraps and exact-fill caret rows', () => {
  const texts = ['hello world', 'a界\t👍🏽z', 'abcde', '', '\t界'];
  for (const width of [1, 4, 5, 9]) {
    const expected = wrap(width, ...texts).page({row: 0}, 100);
    const layout = wrap(width, ...texts);
    assert.equal(layout.screenRowCount, expected.length);
    for (const [index, segment] of expected.entries()) {
      assert.equal(layout.screenIndex(segment), index);
      assert.deepEqual(layout.atScreenIndex(index), segment);
    }
    assert.deepEqual(layout.atScreenIndex(-20), expected[0]);
    assert.deepEqual(layout.atScreenIndex(200), expected.at(-1));
  }
});

test('updates screen row offsets after edits that shift a reusable suffix', () => {
  const texts = ['hello world', '章\t节', 'a', 'abcde', ''];
  let layout = wrap(5, ...texts);
  assert.equal(layout.screenRowCount, 9);

  for (const [width, updated] of [
    [5, ['hello world', 'new first line', 'new second line', ...texts.slice(2)]],
    [5, ['hello world', 'a', 'abcde', '']],
    [5, ['hello world', 'a', 'abcde', '']],
    [9, ['hello world', 'a', 'abcde', '']],
  ]) {
    const expected = wrap(width, ...updated).page({row: 0}, 100);
    layout = new WrappedLines(updated.map(text => ({text})), width, layout);
    assert.equal(layout.screenRowCount, expected.length);
    assert.deepEqual(expected.map((_, index) => layout.atScreenIndex(index)), expected);
  }
});

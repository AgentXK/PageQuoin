import assert from 'node:assert/strict';
import test from 'node:test';
import {EditorBuffer, lineCells} from '../src/editor.mjs';

test('mouse selection extends from a fixed grapheme-safe anchor across lines', () => {
  const text = 'a👩‍🔬z\n第二行\nend';
  const tab = new EditorBuffer('main.tex', {text});

  tab.placeCursorAt(0, 2);
  assert.deepEqual(tab.position, {row: 0, column: 1});
  tab.placeCursorAt(1, 2, true);
  assert.equal(tab.selectedText, '👩‍🔬z\n第二');
  tab.placeCursorAt(0, 0, true);
  assert.deepEqual(tab.selection, {start: 0, end: 1});
  tab.placeCursorAt(0, 1, true);
  assert.equal(tab.selection, null);
  tab.placeCursorAt(2, 999, true);
  assert.equal(tab.selectedText, text.slice(1));

  tab.placeCursorAt(1, 1);
  assert.equal(tab.selection, null);
  assert.deepEqual(tab.position, {row: 1, column: 1});
});

test('selection edits are undoable and normal arrows collapse a selection', () => {
  const text = 'one\ntwo';
  const tab = new EditorBuffer('main.tex', {text});
  tab.placeCursorAt(0, 1);
  tab.placeCursorAt(1, 1, true);
  assert.equal(tab.deleteSelection(), true);
  assert.equal(tab.text, 'owo');
  assert.equal(tab.deleteSelection(), false);
  tab.undo();
  assert.equal(tab.text, text);
  tab.redo();
  assert.equal(tab.text, 'owo');

  tab.key('', {rightArrow: true, shift: true}, 10);
  tab.key('', {rightArrow: true, shift: true}, 10);
  assert.equal(tab.selectedText, 'wo');
  tab.key('', {leftArrow: true}, 10);
  assert.equal(tab.position.column, 1);
  assert.equal(tab.selection, null);

  tab.key('', {leftArrow: true, shift: true}, 10);
  tab.insertText('third\nline');
  assert.equal(tab.text, 'third\nlinewo');
  assert.equal(tab.selection, null);
  tab.undo();
  assert.equal(tab.text, 'owo');

  tab.placeCursorAt(0, 0);
  tab.placeCursorAt(0, 3, true);
  tab.key('x', {}, 10);
  assert.equal(tab.text, 'x');
});

test('selected cells preserve grapheme styling and show the selected hard newline', () => {
  const text = 'a界x';
  const tokens = [{start: 1, end: 2, color: 'blue'}];
  const cells = lineCells(text, 3, 0, 5, tokens, undefined, {start: 1, end: 4});
  assert.deepEqual(cells, [
    {text: 'a', cursor: false},
    {text: '界', cursor: false, color: 'blue', selected: true},
    {text: 'x', cursor: false, selected: true},
    {text: ' ', cursor: true, selected: true},
  ]);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {EditorBuffer} from '../src/editor.mjs';

test('select all covers the entire document including its last newline', () => {
  const text = 'a👩‍🔬\nsecond\n';
  const tab = new EditorBuffer('main.tex', {text});
  tab.placeCursorAt(1, 2);
  tab.selectAll();
  assert.equal(tab.selectedText, text);
  assert.deepEqual(tab.position, {row: 2, column: 0});
  tab.insertText('new content');
  assert.equal(tab.text, 'new content');
  assert.equal(tab.selection, null);
});

test('cutting a logical line gives the exact range and clipboard text', () => {
  const text = 'first\nsecond 👩‍🔬 line\nlast';
  const cases = [
    [0, 1, 'first\n', 'second 👩‍🔬 line\nlast'],
    [1, 8, 'second 👩‍🔬 line\n', 'first\nlast'],
    [2, 3, '\nlast', 'first\nsecond 👩‍🔬 line'],
  ];
  for (const [row, column, clipboard, remaining] of cases) {
    const tab = new EditorBuffer('main.tex', {text});
    tab.placeCursorAt(row, column);
    const cut = tab.lineCut();
    assert.equal(tab.text, text);
    assert.equal(cut.text, clipboard);
    assert.equal(text.slice(cut.start, cut.end), clipboard);
    tab.replace(cut.start, cut.end, '');
    assert.equal(tab.text, remaining);
    tab.insertText(cut.text);
    assert.equal(tab.text, text);
  }
});

test('line cutting covers blank lines, trailing newlines and single lines', () => {
  for (const [text, row, clipboard, remaining] of [
    ['one\n\ntwo', 1, '\n', 'one\ntwo'],
    ['one\n', 0, 'one\n', ''],
    ['one\n', 1, '\n', 'one'],
    ['one', 0, 'one', ''],
    ['', 0, '', ''],
  ]) {
    const tab = new EditorBuffer('main.tex', {text});
    tab.placeCursorAt(row, 0);
    const cut = tab.lineCut();
    assert.equal(cut.text, clipboard);
    tab.replace(cut.start, cut.end, '');
    assert.equal(tab.text, remaining);
  }
});

test('line comments preserve indentation and map the caret past the comment prefix', () => {
  const tab = new EditorBuffer('main.tex', {text: '  \t\\section{内容}\nnext'});
  tab.placeCursorAt(0, 5);
  assert.equal(tab.toggleLineComment(), true);
  assert.equal(tab.text, '  \t% \\section{内容}\nnext');
  assert.deepEqual(tab.position, {row: 0, column: 7});
  assert.equal(tab.toggleLineComment(), true);
  assert.equal(tab.text, '  \t\\section{内容}\nnext');
  assert.deepEqual(tab.position, {row: 0, column: 5});
});

test('a line comment toggles selected lines as a single edit and preserves the selection', () => {
  const text = 'before\n  \\section{A}\n\t%already\n  \nafter';
  const commented = 'before\n  % \\section{A}\n\t% %already\n  \nafter';
  const tab = new EditorBuffer('main.tex', {text});
  tab.placeCursorAt(4, 0);
  tab.placeCursorAt(1, 2, true);
  const selection = tab.selectedText;

  assert.equal(tab.toggleLineComment(), true);
  assert.equal(tab.text, commented);
  assert.equal(tab.selectedText, '\\section{A}\n\t% %already\n  \n');
  assert.deepEqual(tab.position, {row: 1, column: 4});

  tab.undo();
  assert.equal(tab.text, text);
  assert.equal(tab.selectedText, selection);
  assert.deepEqual(tab.position, {row: 1, column: 2});
  tab.redo();
  assert.equal(tab.text, commented);
  assert.equal(tab.selectedText, '\\section{A}\n\t% %already\n  \n');

  assert.equal(tab.toggleLineComment(), true);
  assert.equal(tab.text, text);
  assert.equal(tab.selectedText, selection);
});

test('uncommenting removes one marker and optionally its space', () => {
  const tab = new EditorBuffer('main.tex', {text: '  %first\n\t% second\n  %% third'});
  tab.selectAll();
  assert.equal(tab.toggleLineComment(), true);
  assert.equal(tab.text, '  first\n\tsecond\n  % third');
  const blank = new EditorBuffer('main.tex', {text: ' \t'});
  blank.placeCursorAt(0, 2);
  assert.equal(blank.toggleLineComment(), true);
  assert.equal(blank.text, ' \t% ');
  assert.equal(blank.toggleLineComment(), true);
  assert.equal(blank.text, ' \t');
});

test('commenting across generated delimiter pairs preserves their overtype behavior', () => {
  const tab = new EditorBuffer('main.tex', {text: 'before\n\nafter'});
  tab.placeCursorAt(1, 0);
  tab.key('{', {}, 10);
  tab.selectAll();
  tab.toggleLineComment();
  tab.undo();
  tab.redo();
  assert.equal(tab.text, '% before\n% {}\n% after');
  tab.placeCursorAt(1, 3);
  tab.key('}', {}, 10);
  assert.equal(tab.text, '% before\n% {}\n% after');
  assert.deepEqual(tab.position, {row: 1, column: 4});
});

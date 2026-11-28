import assert from 'node:assert/strict';
import test from 'node:test';
import {EditorBuffer} from '../src/editor.mjs';

test('typing an opener inserts a matching delimiter and leaves the caret inside', () => {
  for (const pair of ['()', '[]', '{}', '""', "''"]) {
    const tab = new EditorBuffer('main.tex', {text: ''});
    tab.key(pair[0], {}, 10);
    assert.equal(tab.text, pair);
    assert.equal(tab.cursor, 1);
    tab.key(pair[1], {}, 10);
    assert.equal(tab.text, pair);
    assert.equal(tab.cursor, 2);
  }

  for (const suffix of [' word', ')', ', next']) {
    const tab = new EditorBuffer('main.tex', {text: suffix});
    tab.key('{', {}, 10);
    assert.equal(tab.text, '{}' + suffix);
    assert.equal(tab.cursor, 1);
  }

  const nextLine = new EditorBuffer('main.tex', {text: 'word\n'});
  nextLine.placeCursorAt(1, 0);
  nextLine.key('"', {}, 10);
  assert.equal(nextLine.text, 'word\n""');
  assert.deepEqual(nextLine.position, {row: 1, column: 1});
});

test('generated closing delimiters move with intervening edits and support nesting', () => {
  const tab = new EditorBuffer('main.tex', {text: ''});
  tab.key('{', {}, 10);
  tab.key('[', {}, 10);
  tab.key('(', {}, 10);
  tab.insertText('界');
  assert.equal(tab.text, '{[(界)]}');
  for (const closing of [')', ']', '}']) tab.key(closing, {}, 10);
  assert.equal(tab.text, '{[(界)]}');
  assert.equal(tab.cursor, tab.text.length);
});

test('only generated closers are skipped or removed with their opener', () => {
  const tab = new EditorBuffer('main.tex', {text: '()'});
  tab.placeCursorAt(0, 1);
  tab.key(')', {}, 10);
  assert.equal(tab.text, '())');
  tab.undo();
  tab.key('', {backspace: true}, 10);
  assert.equal(tab.text, ')');

  const paired = new EditorBuffer('main.tex', {text: ''});
  paired.key('(', {}, 10);
  paired.key('', {backspace: true}, 10);
  assert.equal(paired.text, '');
  assert.equal(paired.cursor, 0);
});

test('apostrophes inside words, escaped delimiters and openers before words are literal', () => {
  const word = new EditorBuffer('main.tex', {text: '𐐀'});
  word.placeCursorAt(0, 2);
  word.key("'", {}, 10);
  assert.equal(word.text, "𐐀'");
  word.key('s', {}, 10);
  assert.equal(word.text, "𐐀's");

  const escape = new EditorBuffer('main.tex', {text: '\\'});
  escape.placeCursorAt(0, 1);
  escape.key('{', {}, 10);
  assert.equal(escape.text, '\\{');

  const evenEscape = new EditorBuffer('main.tex', {text: '\\\\'});
  evenEscape.placeCursorAt(0, 2);
  evenEscape.key('{', {}, 10);
  assert.equal(evenEscape.text, '\\\\{}');

  const escapedCloser = new EditorBuffer('main.tex', {text: ''});
  escapedCloser.key('{', {}, 10);
  escapedCloser.key('\\', {}, 10);
  escapedCloser.key('}', {}, 10);
  assert.equal(escapedCloser.text, '{\\}}');
  assert.equal(escapedCloser.cursor, 3);
  escapedCloser.key('}', {}, 10);
  assert.equal(escapedCloser.text, '{\\}}');
  assert.equal(escapedCloser.cursor, 4);

  const ahead = new EditorBuffer('main.tex', {text: 'content'});
  ahead.key('[', {}, 10);
  assert.equal(ahead.text, '[content');
});

test('typing a delimiter wraps a multiline selection in one edit', () => {
  const text = 'pre 👩‍🔬\n第二行 end';
  const tab = new EditorBuffer('main.tex', {text});
  tab.placeCursorAt(1, 3);
  tab.placeCursorAt(0, 4, true);
  tab.key('"', {}, 10);
  assert.equal(tab.text, 'pre "👩‍🔬\n第二行" end');
  assert.equal(tab.selection, null);
  assert.deepEqual(tab.position, {row: 1, column: 3});
  tab.undo();
  assert.equal(tab.text, text);
  tab.redo();
  assert.equal(tab.text, 'pre "👩‍🔬\n第二行" end');
  assert.deepEqual(tab.position, {row: 1, column: 3});
});

test('undo and redo restore the caret and the generated closer', () => {
  const tab = new EditorBuffer('main.tex', {text: ''});
  tab.key('{', {}, 10);
  tab.undo();
  assert.equal(tab.text, '');
  tab.redo();
  assert.equal(tab.text, '{}');
  assert.equal(tab.cursor, 1);

  tab.key('', {backspace: true}, 10);
  assert.equal(tab.text, '');
  tab.undo();
  assert.equal(tab.text, '{}');
  assert.equal(tab.cursor, 1);
  tab.key('}', {}, 10);
  assert.equal(tab.text, '{}');
  assert.equal(tab.cursor, 2);
});

test('paste and multi-character keyboard input insert literal text', () => {
  const tab = new EditorBuffer('main.tex', {text: ''});
  tab.insertText('{');
  tab.key(' [word', {}, 10);
  assert.equal(tab.text, '{ [word');
  assert.equal(tab.cursor, tab.text.length);
});

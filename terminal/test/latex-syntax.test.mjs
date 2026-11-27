import assert from 'node:assert/strict';
import test from 'node:test';
import {lineCells} from '../src/editor.mjs';
import {latexTokens} from '../src/latex-syntax.mjs';

function coloredParts(text) {
  return Array.from(latexTokens(text), ({start, end, color}) => [text.slice(start, end), color]);
}

test('highlights optional and named arguments, escaped symbols and TeX comments', () => {
  assert.deepEqual(coloredParts('\\usepackage[sort]{my_package} \\% prose % \\section{Ignored}'), [
    ['\\usepackage', 'cyanBright'],
    ['[', 'blueBright'],
    [']', 'blueBright'],
    ['{', 'blueBright'],
    ['my_package', 'yellowBright'],
    ['}', 'blueBright'],
    ['\\%', 'cyanBright'],
    ['% \\section{Ignored}', 'greenBright'],
  ]);
  assert.deepEqual(coloredParts('\\\\% comment'), [['\\\\', 'cyanBright'], ['% comment', 'greenBright']]);
});

test('distinguishes math syntax and verbatim text', () => {
  assert.deepEqual(coloredParts('\\[x_{ij}^2\\] $$ \\verb*|100%| % comment'), [
    ['\\[', 'magentaBright'],
    ['_', 'magentaBright'],
    ['{', 'blueBright'],
    ['}', 'blueBright'],
    ['^', 'magentaBright'],
    ['\\]', 'magentaBright'],
    ['$$', 'magentaBright'],
    ['\\verb', 'cyanBright'],
    ['*|100%|', 'yellowBright'],
    ['% comment', 'greenBright'],
  ]);
});

test('syntax colors follow graphemes, tabs and clipped viewport cells', () => {
  const ascii = '\\emph{value}';
  assert.deepEqual(lineCells(ascii, 5, 3, 4, latexTokens(ascii)), [
    {text: 'p', cursor: false, color: 'cyanBright'},
    {text: 'h', cursor: false, color: 'cyanBright'},
    {text: '{', cursor: true, color: 'blueBright'},
    {text: 'v', cursor: false},
  ]);

  const unicode = '前\t%文';
  assert.deepEqual(lineCells(unicode, 3, 3, 3, latexTokens(unicode)), [
    {text: ' ', cursor: false},
    {text: '%', cursor: false, color: 'greenBright'},
    {text: ' ', cursor: true, color: 'greenBright'},
  ]);
});

test('only consumes syntax ranges needed for the viewport', () => {
  function* ranges() {
    yield {start: 0, end: 1, color: 'cyanBright'};
    assert.fail('Read syntax ranges outside the viewport');
  }
  assert.deepEqual(lineCells('a long line', -1, 0, 1, ranges()), [
    {text: 'a', cursor: false, color: 'cyanBright'},
  ]);
});

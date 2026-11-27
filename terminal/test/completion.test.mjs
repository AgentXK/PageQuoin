import assert from 'node:assert/strict';
import test from 'node:test';
import {latexCompletions} from '../src/completion.mjs';

test('completes a command prefix and replaces a suffix at the caret', () => {
  assert.deepEqual(latexCompletions('先😊 \\seczzz{}', 8), {
    start: 4, end: 11, items: [{label: '\\section', text: '\\section'}],
  });
  assert.deepEqual(latexCompletions('\\alp', 4), {
    start: 0, end: 4, items: [{label: '\\alpha', text: '\\alpha'}],
  });
  assert.equal(latexCompletions('\\section', 8), null);
  assert.equal(latexCompletions('\\fra', 4).items[0].text, '\\frac');
});

test('returns command and environment matches past the first six candidates', () => {
  assert.equal(latexCompletions('\\', 1).items[6].text, '\\subsubsection');
  assert.equal(latexCompletions('\\text', 5).items[6].text, '\\textsl');
  assert.equal(latexCompletions('\\begin{', 7).items[6].text, 'tabular');
});

test('completes begin and end environment names without replacing braces', () => {
  const match = latexCompletions('  \\begin{aligzzz}', 13);
  assert.deepEqual(match, {
    start: 9, end: 16,
    items: [
      {label: 'align', text: 'align'},
      {label: 'align*', text: 'align*'},
      {label: 'aligned', text: 'aligned'},
    ],
  });
  assert.equal(latexCompletions('\\end {Bmat', 10).items[0].text, 'Bmatrix');
});

test('preserves plain text, escaped commands, comments and inline verbatim', () => {
  const values = ['section', '\\\\sec', '% \\sec', '\\\\% \\sec', '\\verb*|\\sec', '\\verb|\\sec|', '\\\\begin{ali'];
  for (const value of values) {
    assert.equal(latexCompletions(value, value.length), null);
  }
  assert.equal(latexCompletions('\\verb|%| \\sec', 13).items[0].text, '\\section');
  assert.equal(latexCompletions('\\% \\sec', 7).items[0].text, '\\section');
  assert.equal(latexCompletions('\\\\\\sec', 6).items[0].text, '\\section');
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {createMouseDecoder} from '../src/mouse.mjs';

test('decodes terminal mouse reports split at any input boundary', () => {
  const click = '\u001b[<0;42;19M';
  for (let index = 1; index < click.length; index++) {
    const events = [];
    const decode = createMouseDecoder(event => events.push(event));
    decode('x' + click.slice(0, index));
    assert.deepEqual(events, []);
    decode(click.slice(index) + '\u001b[<65;3;5M\u001b[<0;42;19m');
    assert.deepEqual(events, [
      {type: 'click', x: 41, y: 18},
      {type: 'wheel', x: 2, y: 4, delta: 1},
      {type: 'release', x: 41, y: 18},
    ]);
  }
});

test('ignores reports inside split bracketed paste and unrelated input', () => {
  const events = [];
  const decode = createMouseDecoder(event => events.push(event));
  decode('\u001b[A\u001b[20');
  decode('0~paste \u001b[<0;3;5M\u001b[');
  decode('201~\u001b[<2;3;5M\u001b[<34;3;5M\u001b[<0;0;5M\u001b[<68;3;5M');
  assert.deepEqual(events, [{type: 'wheel', x: 2, y: 4, delta: -1}]);
});

test('reports left-button dragging and ignores other mouse motion', () => {
  const events = [];
  const decode = createMouseDecoder(event => events.push(event));
  decode('\u001b[<32;11;');
  decode('7M\u001b[<35;11;7M\u001b[<0;11;7m');
  assert.deepEqual(events, [
    {type: 'drag', x: 10, y: 6},
    {type: 'release', x: 10, y: 6},
  ]);
});

import {createContext, createElement, useContext, useEffect, useEffectEvent} from 'react';
import {usePaste, useStdin, useStdout} from 'ink';

const escape = '\u001b';
const pasteStart = escape + '[200~';
const pasteEnd = escape + '[201~';
const report = /^\u001b\[<(\d{1,3});(\d{1,6});(\d{1,6})([Mm])/;
const partialReport = /^\u001b\[<\d{0,3}(?:;\d{0,6}(?:;\d{0,6})?)?$/;
const maxReportLength = '\u001b[<000;000000;000000M'.length;
const MouseContext = createContext(false);

export function createMouseDecoder(onMouse) {
  let pending = '';
  let inPaste = false;

  return chunk => {
    const input = pending + chunk;
    pending = '';
    let offset = 0;
    while (offset < input.length) {
      if (inPaste) {
        const end = input.indexOf(pasteEnd, offset);
        if (end === -1) {
          pending = input.slice(Math.max(offset, input.length - pasteEnd.length + 1));
          return;
        }
        inPaste = false;
        offset = end + pasteEnd.length;
        continue;
      }

      const start = input.indexOf(escape, offset);
      if (start === -1) return;
      if (input.startsWith(pasteStart, start)) {
        inPaste = true;
        offset = start + pasteStart.length;
        continue;
      }

      const tail = input.slice(start, start + maxReportLength);
      const match = report.exec(tail);
      if (match) {
        const [sequence, button, column, row, action] = match;
        // Clear the Shift, Alt and Control bits, leaving the button and motion bits.
        const code = Number(button) & ~(4 | 8 | 16);
        const x = Number(column) - 1;
        const y = Number(row) - 1;
        if (x >= 0 && y >= 0) {
          if (action === 'm' && (code === 0 || code === 3)) onMouse({type: 'release', x, y});
          else if (action === 'M') {
            if (code === 0) onMouse({type: 'click', x, y});
            else if (code === 32) onMouse({type: 'drag', x, y});
            else if (code === 64 || code === 65) onMouse({type: 'wheel', x, y, delta: code === 64 ? -1 : 1});
          }
        }
        offset = start + sequence.length;
      } else {
        if (start + tail.length === input.length && (pasteStart.startsWith(tail) || partialReport.test(tail))) {
          pending = tail;
          return;
        }
        offset = start + 1;
      }
    }
  };
}

function supportsMouse(stdin, stdout) {
  return Boolean(stdin.isTTY && stdout.isTTY && process.env.TERM !== 'dumb');
}

export function startMouseTracking(stdin, stdout) {
  if (!supportsMouse(stdin, stdout)) return () => {};
  stdout.write(escape + '[?1006h' + escape + '[?1002h');

  let active = true;
  const stop = () => {
    if (!active) return;
    active = false;
    process.off('exit', stop);
    if (stdout.writable) stdout.write(escape + '[?1002l' + escape + '[?1006l');
  };
  process.once('exit', stop);
  return stop;
}

export function MouseTracking({children}) {
  const {stdin} = useStdin();
  const {stdout} = useStdout();
  const enabled = supportsMouse(stdin, stdout);
  // The picker also needs paste boundaries while mouse reporting is enabled.
  usePaste(() => {}, {isActive: enabled});
  useEffect(() => startMouseTracking(stdin, stdout), [stdin, stdout]);
  return createElement(MouseContext.Provider, {value: enabled}, children);
}

export function useMouse(handler, {isActive = true} = {}) {
  const {stdin} = useStdin();
  const enabled = useContext(MouseContext);
  const onMouse = useEffectEvent(handler);
  useEffect(() => {
    if (!enabled || !isActive) return;
    const handleChunk = createMouseDecoder(onMouse);
    // Observe data from Ink's reads without switching the stream to flowing mode.
    stdin.prependListener('data', handleChunk);
    return () => stdin.off('data', handleChunk);
  }, [stdin, enabled, isActive]);
}

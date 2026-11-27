import React, {useRef, useState} from 'react';
import {Box, Text, measureElement, useApp, useInput, useWindowSize} from 'ink';
import {App} from './app.mjs';
import {safeText} from './editor.mjs';
import {useMouse} from './mouse.mjs';
import {palette} from './theme.mjs';

const h = React.createElement;
const removeLabel = ' × ';

export function ResumePicker({sessions: initialSessions, open, remove}) {
  const {exit} = useApp();
  const {columns, rows} = useWindowSize();
  const panel = useRef(null);
  const pending = useRef(false);
  const [sessions, setSessions] = useState(initialSessions);
  const [selected, setSelected] = useState(0);
  const [workspace, setWorkspace] = useState(null);
  const [loading, setLoading] = useState('');
  const [error, setError] = useState('');
  const capacity = Math.max(1, rows - 6);
  const offset = Math.max(0, selected - capacity + 1);

  function move(direction) {
    setSelected(index => Math.max(0, Math.min(sessions.length - 1, index + direction)));
    setError('');
  }

  function act(index, label, action, onSuccess) {
    if (pending.current || !sessions[index]) return;
    pending.current = true;
    setSelected(index);
    setError('');
    setLoading(label);
    void action(sessions[index]).then(onSuccess, error => {
      setError(error.message);
    }).finally(() => {
      pending.current = false;
      setLoading('');
    });
  }

  function submit(index) {
    act(index, 'Opening project…', open, setWorkspace);
  }

  function removeAt(index) {
    act(index, 'Removing project…', remove, () => {
      const remaining = sessions.filter((_, item) => item !== index);
      setSessions(remaining);
      setSelected(Math.max(0, Math.min(index, remaining.length - 1)));
    });
  }

  useInput((input, key) => {
    if (key.eventType === 'release' || loading) return;
    if (key.escape || (key.ctrl && ['c', 'q'].includes(input.toLowerCase()))) {
      exit();
    } else if (key.upArrow || key.downArrow) {
      move(key.upArrow ? -1 : 1);
    } else if (key.return) {
      submit(selected);
    } else if (key.eventType !== 'repeat' && (key.delete || (key.ctrl && input.toLowerCase() === 'd'))) {
      removeAt(selected);
    }
  }, {isActive: workspace === null});

  useMouse(event => {
    if (loading || !panel.current) return;
    const {x, y, width, height} = measureElement(panel.current);
    if (event.x <= x || event.x >= x + width - 1 || event.y <= y || event.y >= y + height - 1) return;
    if (event.type === 'wheel') {
      move(event.delta);
    } else if (event.type === 'click') {
      const row = event.y - y - 2;
      if (row < 0 || row >= capacity || offset + row >= sessions.length) return;
      if (event.x >= x + width - 1 - removeLabel.length) removeAt(offset + row);
      else submit(offset + row);
    }
  }, {isActive: workspace === null});

  if (workspace) return h(App, workspace);
  return h(Box, {ref: panel, width: columns, flexDirection: 'column', borderStyle: 'round',
    borderColor: palette.focusBorder},
    h(Box, {height: 1, flexShrink: 0},
      h(Text, {color: palette.accent, bold: true, wrap: 'truncate-end'}, ' Resume project')),
    ...sessions.slice(offset, offset + capacity).map(({root}, index) => {
      const current = index + offset === selected;
      const color = current ? palette.selectionText : undefined;
      return h(Box, {key: root, height: 1, flexShrink: 0, backgroundColor: current ? palette.selection : undefined},
        h(Text, {color, bold: current}, current ? ' › ' : '   '),
        h(Box, {flexGrow: 1, flexBasis: 0, minWidth: 0},
          h(Text, {color, bold: current, wrap: 'truncate-start'}, safeText(root))),
        h(Text, {color: current ? palette.selectionText : palette.muted}, removeLabel));
    }),
    sessions.length === 0 && h(Text, {color: palette.muted, wrap: 'truncate-end'}, ' No recent projects.'),
    (error || loading) && h(Text, {color: error ? palette.error : palette.accent, wrap: 'truncate-end'},
      ' ' + (error ? safeText(error) : loading)),
    rows >= 7 && h(Box, {height: 1, flexShrink: 0}),
    h(Box, {height: 1, flexShrink: 0},
      h(Text, {color: palette.muted, wrap: 'truncate-end'},
        sessions.length ? ' ↑/↓ Select   Enter Open   Ctrl+D/Delete Remove   Esc Cancel   ' +
          (selected + 1) + '/' + sessions.length : ' Esc Cancel')));
}

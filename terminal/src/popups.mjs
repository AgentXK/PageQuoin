import React from 'react';
import {Box, Text} from 'ink';
import stringWidth from 'string-width';
import {safeText} from './editor.mjs';
import {palette} from './theme.mjs';

const h = React.createElement;
// Ink fills the popup with unstyled spaces for an unknown color.
const terminalBackground = 'default';

export function floatingLayout(columns, height, anchor = 2) {
  const insetX = columns >= 8 ? 1 : 0;
  const insetY = height >= 6 ? 1 : 0;
  const availableWidth = columns - 2 * insetX;
  const availableHeight = height - 2 * insetY;
  const mainWidth = Math.min(availableWidth, 62, Math.max(24, Math.floor(columns * 0.66)));
  const mainHeight = Math.min(availableHeight, 16, Math.max(5, Math.floor(height * 0.64)));
  const logWidth = Math.min(availableWidth, 78, Math.max(24, Math.floor(columns * 0.62)));
  const logHeight = Math.min(availableHeight, 18, Math.max(4, Math.floor(height * 0.48)));
  const showFilter = mainHeight >= 5;
  const showHint = mainHeight >= 7;

  return {
    main: {
      left: Math.max(insetX, Math.min(Math.floor(anchor), columns - insetX - mainWidth)),
      top: insetY,
      width: mainWidth,
      height: mainHeight,
      rows: Math.max(1, mainHeight - 3 - Number(showFilter) - Number(showHint)),
      showFilter,
      showHint,
    },
    log: {
      left: columns - insetX - logWidth,
      top: height - insetY - logHeight,
      width: logWidth,
      height: logHeight,
      rows: Math.max(1, logHeight - 3),
    },
  };
}

export function completionLayout({columns, height, cursorX, cursorY, items, index}) {
  if (columns < 8 || !items.length || cursorX < 0 || cursorX >= columns || cursorY < 0 || cursorY >= height) {
    return null;
  }

  const above = cursorY;
  const below = height - cursorY - 1;
  const visibleRows = Math.min(items.length, 6);
  const opensBelow = below >= visibleRows + 2 || below >= above;
  const rows = Math.min(visibleRows, (opensBelow ? below : above) - 2);
  if (rows < 1) return null;

  const labelWidth = Math.max(...items.map(({label}) => stringWidth(safeText(label))));
  const width = Math.min(columns, Math.max(12, labelWidth + 4));
  const popupHeight = rows + 2;
  return {
    left: Math.max(0, Math.min(cursorX - 1, columns - width)),
    top: opensBelow ? cursorY + 1 : cursorY - popupHeight,
    width,
    height: popupHeight,
    offset: Math.max(0, Math.min(index - rows + 1, items.length - rows)),
    rows,
  };
}

function line(text, props = {}) {
  return h(Text, {wrap: 'truncate-end', ...props}, text);
}

export function CompletionPopup({frame, items, index, panelRef}) {
  if (!frame) return null;
  const {left, top, width, height, offset, rows} = frame;
  return h(Box, {ref: panelRef, position: 'absolute', left, top, width, height, flexDirection: 'column',
    borderStyle: 'round', overflow: 'hidden', backgroundColor: terminalBackground,
    borderColor: palette.focusBorder},
  ...items.slice(offset, offset + rows).map(({label}, row) => {
    const selected = offset + row === index;
    return h(Box, {key: offset + row, height: 1, flexShrink: 0,
      backgroundColor: selected ? palette.selection : undefined},
      line(' ' + safeText(label), {
        color: selected ? palette.selectionText : undefined, bold: selected,
      }));
  }));
}

function Popup({panelRef, closeRef, frame, title, focused, children}) {
  if (frame.width < 3 || frame.height < 4) return null;
  const closeWidth = Math.min(3, frame.width - 2);
  return h(Box, {ref: panelRef, position: 'absolute', left: frame.left, top: frame.top, width: frame.width,
    height: frame.height, flexDirection: 'column', borderStyle: 'round', overflow: 'hidden',
    backgroundColor: terminalBackground,
    borderColor: focused ? palette.focusBorder : palette.border},
  h(Box, {height: 1, flexShrink: 0},
    h(Box, {flexGrow: 1, flexShrink: 1, minWidth: 0},
      line(' ' + title, {bold: true, color: focused ? palette.accent : undefined})),
    h(Box, {ref: closeRef, width: closeWidth, flexShrink: 0, 'aria-role': 'button', 'aria-label': 'Close ' + title},
      line(closeWidth === 3 ? ' × ' : '×', {color: palette.muted}))),
  children);
}

export function MainFilePopup({panelRef, closeRef, frame, picker, options}) {
  const entries = options.slice(picker.offset, picker.offset + frame.rows).map(({file, text}, index) => {
    const selected = picker.offset + index === picker.selected;
    const current = file === picker.activeFile;
    return h(Box, {key: file ?? 'automatic', height: 1, flexShrink: 0,
      backgroundColor: selected ? palette.selection : undefined},
      line((selected ? ' › ' : '   ') + (current ? '✓ ' : '  ') + safeText(text), {
        color: selected ? palette.selectionText : current ? palette.accent : undefined, bold: selected || current,
      }));
  });
  if (!entries.length) entries.push(line(' No matching TeX files', {key: 'empty', color: palette.muted}));

  return h(Popup, {panelRef, closeRef, frame, title: 'MAIN DOCUMENT', focused: true},
    frame.showFilter && line(picker.query ? ' Filter · ' + safeText(picker.query) + '▏' : ' Type to filter files',
      {color: picker.query ? palette.accent : palette.muted, wrap: picker.query ? 'truncate-start' : 'truncate-end'}),
    ...entries,
    ...Array.from({length: frame.rows - entries.length}, (_, index) => line(' ', {key: 'blank-' + index})),
    frame.showHint && h(Box, {height: 1, flexShrink: 0},
      line(' ↑/↓ Choose   Enter Apply   Esc Cancel', {color: palette.muted})));
}

export function BuildLogPopup({panelRef, closeRef, frame, lines, focused}) {
  const hasLog = lines.some(Boolean);
  const visible = hasLog ? lines.slice(0, frame.rows) : ['No build log yet'];
  return h(Popup, {panelRef, closeRef, frame, title: 'BUILD LOG', focused},
    ...visible.map((text, index) => line(' ' + safeText(text), {key: index, color: hasLog ? undefined : palette.muted})));
}

import stringWidth from 'string-width';

const graphemes = new Intl.Segmenter(undefined, {granularity: 'grapheme'});
const nonPrintableASCII = /[^\x20-\x7e]/;
export const safeText = text => text.replace(/[\p{Cc}\u202a-\u202e\u2066-\u2069]/gu, '�');

function previous(text, index) {
  return graphemes.segment(text).containing(index - 1)?.index ?? 0;
}

function next(text, index) {
  const segment = graphemes.segment(text).containing(index);
  return segment ? segment.index + segment.segment.length : text.length;
}

function segmentWidth(text, column) {
  return text === '\t' ? 4 - column % 4 : stringWidth(safeText(text));
}

function offsetAtCell(text, cell) {
  if (cell <= 0) return 0;
  if (!nonPrintableASCII.test(text)) return Math.min(text.length, cell);
  let column = 0;
  for (const part of graphemes.segment(text)) {
    column += segmentWidth(part.segment, column);
    if (cell < column) return part.index;
  }
  return text.length;
}

export function insertable(text) {
  return text.replace(/\r\n?/g, '\n').replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, '');
}

export class EditorBuffer {
  cursor = 0;
  top = 0;
  wrapStart = 0;
  scrollDetached = false;
  #undo = [];
  #redo = [];
  #lines;
  #column;
  #anchor;

  constructor(file, snapshot) {
    this.file = file;
    this.snapshot = snapshot;
    this.text = snapshot.text;
  }

  get dirty() { return this.text !== this.snapshot.text; }

  get selection() {
    if (this.#anchor === undefined || this.#anchor === this.cursor) return null;
    return {start: Math.min(this.#anchor, this.cursor), end: Math.max(this.#anchor, this.cursor)};
  }

  get selectedText() {
    const range = this.selection;
    return range ? this.text.slice(range.start, range.end) : '';
  }

  clearSelection() {
    this.#anchor = undefined;
  }

  get lines() {
    if (!this.#lines) {
      let start = 0;
      this.#lines = this.text.split('\n').map(text => {
        const line = {text, start};
        start += text.length + 1;
        return line;
      });
    }
    return this.#lines;
  }

  get position() {
    return this.#positionAt(this.cursor);
  }

  #positionAt(cursor) {
    const lines = this.lines;
    let low = 0;
    let high = lines.length;
    while (high - low > 1) {
      const middle = Math.floor((high + low) / 2);
      if (lines[middle].start <= cursor) low = middle;
      else high = middle;
    }
    return {row: low, column: cursor - lines[low].start};
  }

  restorePosition({cursor, top, wrapStart = 0}) {
    this.cursor = Math.min(cursor, this.text.length);
    const {row, column} = this.position;
    const line = this.lines[row];
    const segment = graphemes.segment(line.text).containing(column);
    if (segment) this.cursor = line.start + segment.index;
    this.top = Math.min(top, row);
    this.wrapStart = this.top === top ? wrapStart : 0;
    this.clearSelection();
  }

  placeCursor(row, cell) {
    const line = this.lines[Math.max(0, row)];
    this.placeCursorAt(row, line ? offsetAtCell(line.text, cell) : 0);
  }

  placeCursorAt(row, column, extend = false) {
    const line = this.lines[Math.max(0, row)];
    this.#extendSelection(extend);
    if (line) {
      const offset = Math.max(0, Math.min(column, line.text.length));
      const boundary = offset > 0 && offset < line.text.length &&
          nonPrintableASCII.test(line.text.slice(offset - 1, offset + 1))
        ? graphemes.segment(line.text).containing(offset)?.index ?? offset
        : offset;
      this.cursor = line.start + boundary;
    } else {
      this.cursor = this.text.length;
    }
    this.#column = undefined;
  }

  #extendSelection(extend) {
    if (extend) this.#anchor ??= this.cursor;
    else this.clearSelection();
  }

  insertText(text) {
    if (!text) return;
    const range = this.selection;
    this.replace(range?.start ?? this.cursor, range?.end ?? this.cursor, text);
  }

  deleteSelection() {
    const range = this.selection;
    if (!range) return false;
    this.replace(range.start, range.end, '');
    return true;
  }

  replace(start, end, value) {
    if (start === end && !value) return;
    const edit = {start, before: this.cursor, old: this.text.slice(start, end), value};
    this.#undo.push(edit);
    if (this.#undo.length > 100) this.#undo.shift();
    this.#redo = [];
    this.#apply(start, edit.old.length, value, start + value.length);
  }

  #apply(start, length, value, cursor) {
    this.text = this.text.slice(0, start) + value + this.text.slice(start + length);
    this.cursor = cursor;
    this.#lines = undefined;
    this.#column = undefined;
    this.clearSelection();
  }

  undo() {
    const edit = this.#undo.pop();
    if (!edit) return;
    this.#redo.push(edit);
    this.#apply(edit.start, edit.value.length, edit.old, edit.before);
  }

  redo() {
    const edit = this.#redo.pop();
    if (!edit) return;
    this.#undo.push(edit);
    this.#apply(edit.start, edit.old.length, edit.value, edit.start + edit.value.length);
  }

  moveHorizontal(direction) {
    const {row, column} = this.position;
    const {start, text} = this.lines[row];
    if (direction < 0) this.cursor = column ? start + previous(text, column) : Math.max(0, start - 1);
    else this.cursor = column < text.length ? start + next(text, column) : Math.min(this.text.length, this.cursor + 1);
    this.#column = undefined;
  }

  moveVertical(amount, wrap) {
    const {row, column} = this.position;
    if (wrap) {
      const current = wrap.rowAt(row, column);
      const target = wrap.advance(current, amount);
      if (current.row === target.row && current.part === target.part) return;
      this.#column ??= wrap.cellAt(current, column);
      this.cursor = this.lines[target.row].start + wrap.columnAt(target, this.#column);
      return;
    }
    const target = this.lines[Math.max(0, Math.min(this.lines.length - 1, row + amount))];
    this.#column ??= column;
    const desired = Math.min(target.text.length, this.#column);
    this.cursor = target.start + (graphemes.segment(target.text).containing(desired)?.index ?? desired);
  }

  find(query) {
    let index = this.text.indexOf(query, this.cursor + 1);
    if (index < 0) index = this.text.indexOf(query);
    if (index < 0) return false;
    this.cursor = index;
    this.#column = undefined;
    this.clearSelection();
    return true;
  }

  key(input, key, pageRows, wrap) {
    const {row, column} = this.position;
    const {start, text} = this.lines[row];
    const cursor = this.cursor;
    const range = this.selection;
    if (key.leftArrow || key.rightArrow || key.upArrow || key.downArrow || key.pageUp || key.pageDown || key.home || key.end) {
      this.#extendSelection(key.shift);
      if (range && !key.shift && (key.leftArrow || key.rightArrow)) {
        this.cursor = key.leftArrow ? range.start : range.end;
        this.#column = undefined;
        return;
      }
    }
    if (key.upArrow || key.downArrow) this.moveVertical(key.upArrow ? -1 : 1, wrap);
    else if (key.pageUp || key.pageDown) this.moveVertical(key.pageUp ? -pageRows : pageRows, wrap);
    else if (key.leftArrow || key.rightArrow) this.moveHorizontal(key.leftArrow ? -1 : 1);
    else if (key.home || key.end) {
      this.cursor = start + (key.end ? text.length : 0);
      this.#column = undefined;
    } else if (key.backspace) {
      if (!this.deleteSelection()) this.replace(column ? start + previous(text, column) : Math.max(0, cursor - 1), cursor, '');
    } else if (key.delete) {
      if (!this.deleteSelection()) this.replace(cursor, column < text.length ? start + next(text, column) : Math.min(this.text.length, cursor + 1), '');
    } else if (key.return) {
      const insertion = range ? this.#positionAt(range.start) : {row, column};
      const prefix = this.lines[insertion.row].text.slice(0, insertion.column);
      this.insertText('\n' + (prefix.match(/^\s*/)?.[0] ?? ''));
    } else if (key.tab) this.insertText('  ');
    else if (!key.ctrl && !key.meta && !key.escape) this.insertText(insertable(input));
  }
}

export function lineCells(text, caret, left, width, tokens, segment, selection) {
  const cells = [];
  const start = segment?.start ?? 0;
  const end = segment?.end ?? text.length;
  const source = segment ? text.slice(start, end) : text;
  let column = segment?.left ?? 0;
  let ranges = tokens?.[Symbol.iterator]();
  let range;
  function append(value, position) {
    while (ranges && (!range || range.end <= position)) {
      range = ranges.next().value;
      if (!range) ranges = undefined;
    }
    const cell = {text: value, cursor: position === caret};
    if (range?.start <= position) cell.color = range.color;
    if (selection && position >= selection.start && position < selection.end) cell.selected = true;
    cells.push(cell);
  }

  if (!nonPrintableASCII.test(source)) {
    const limit = Math.min(end, start + left + width - column);
    for (let index = start + Math.max(0, left - column); index < limit; index++) {
      append(text[index], index);
    }
    column += source.length;
  } else {
    for (const part of graphemes.segment(source)) {
      const value = part.segment === '\t' ? ' '.repeat(4 - column % 4) : safeText(part.segment);
      const size = stringWidth(value);
      if (column + size > left && column < left + width) {
        const clipped = column < left || column + size > left + width;
        append(clipped ? ' '.repeat(Math.min(column + size, left + width) - Math.max(column, left)) : value, start + part.index);
      }
      column += size;
      if (column >= left + width) break;
    }
  }
  const newlineSelected = selection && selection.start <= text.length && selection.end > text.length;
  if (end === text.length && column >= left && column < left + width && (caret === text.length || newlineSelected)) {
    const cell = {text: ' ', cursor: caret === text.length};
    if (newlineSelected) cell.selected = true;
    cells.push(cell);
  }
  return cells;
}

export function visualColumn(text, index) {
  const prefix = text.slice(0, index);
  if (!nonPrintableASCII.test(prefix)) return prefix.length;
  let column = 0;
  for (const part of graphemes.segment(prefix)) {
    column += segmentWidth(part.segment, column);
  }
  return column;
}

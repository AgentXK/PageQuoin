import stringWidth from 'string-width';
import {safeText} from './editor.mjs';

const graphemes = new Intl.Segmenter(undefined, {granularity: 'grapheme'});
const nonPrintableASCII = /[^\x20-\x7e]/;
const breakableSpace = /^[ \t\u1680\u2000-\u2006\u2008-\u200B\u205F\u3000]$/u;

function cellWidth(text, column) {
  if (text === '\t') return 4 - column % 4;
  const first = text.charCodeAt(0);
  if (text.length === 1 && first >= 0x20 && first <= 0x7e) return 1;
  return stringWidth(safeText(text));
}

function asciiEnd(text, start, width) {
  const limit = Math.min(start + width, text.length);
  if (limit === text.length) return limit;
  const visible = text.slice(start, limit);
  if (text[limit] === ' ' && /[^ ]/.test(visible)) {
    // Keep a separator at the right edge with the word it follows.
    let end = limit + 1;
    while (text[end] === ' ') end++;
    return end;
  }
  const separator = visible.lastIndexOf(' ');
  if (separator < 0 || !/[^ ]/.test(visible.slice(0, separator))) return limit;
  const wordStart = start + separator + 1;
  const word = text.slice(wordStart, wordStart + width + 1);
  return word.length <= width || word.includes(' ') ? wordStart : limit;
}

export class WrappedLines {
  #lines;
  #width;
  #layouts = new Map();
  #screenStarts;
  #previousIndex;

  constructor(lines, width, previousLayout) {
    this.#lines = lines.length ? lines : [{text: ''}];
    this.#width = Math.max(1, Math.floor(width));
    if (previousLayout?.#width === this.#width && previousLayout.#screenStarts) {
      this.#previousIndex = {lines: previousLayout.#lines, starts: previousLayout.#screenStarts};
    }
  }

  #newLayout(row) {
    const text = this.#lines[row].text;
    const ascii = !nonPrintableASCII.test(text);
    const fixed = ascii && (text.length <= this.#width || !text.includes(' '));
    const layout = {row, text, ascii, fixed, parts: [], done: false};
    if (!ascii) {
      layout.iterator = graphemes.segment(text)[Symbol.iterator]();
      layout.pending = [];
    }
    return layout;
  }

  #layout(row) {
    let layout = this.#layouts.get(row);
    if (!layout) {
      layout = this.#newLayout(row);
      this.#layouts.set(row, layout);
    }
    return layout;
  }

  #glyphAt(layout, index) {
    if (index === layout.pending.length && layout.iterator) {
      const next = layout.iterator.next();
      if (next.done) layout.iterator = undefined;
      else layout.pending.push(next.value);
    }
    return layout.pending[index];
  }

  #wordFits(layout, column) {
    let width = 0;
    for (let index = 0; ; index++) {
      const entry = this.#glyphAt(layout, index);
      if (!entry || breakableSpace.test(entry.segment)) return true;
      width += cellWidth(entry.segment, column + width);
      if (width > this.#width) return false;
    }
  }

  #unicodeEnd(layout, start, left) {
    let end = start;
    let right = left;
    let consumed = 0;
    let hasWord = false;
    let boundary;

    for (let entry = this.#glyphAt(layout, consumed); entry; entry = this.#glyphAt(layout, consumed)) {
      const {index, segment} = entry;
      const size = cellWidth(segment, right);
      const space = breakableSpace.test(segment);
      if (right > left && right - left + size > this.#width && !(space && hasWord)) {
        if (boundary && this.#wordFits(layout, boundary.right)) {
          ({end, right} = boundary);
          consumed = 0;
        }
        break;
      }
      end = index + segment.length;
      right += size;
      consumed++;
      if (!space) hasWord = true;
      else if (hasWord) {
        boundary = {end, right};
        // Only glyphs after the latest break can spill into the next row.
        layout.pending.splice(0, consumed);
        consumed = 0;
      }
    }

    layout.pending.splice(0, consumed);
    return {end, right};
  }

  #boundary(layout, start, left) {
    if (layout.ascii) {
      const end = asciiEnd(layout.text, start, this.#width);
      return {end, right: end};
    }
    return this.#unicodeEnd(layout, start, left);
  }

  #isLastPart(text, end, left, right) {
    // Keep a separate empty row for a caret exactly after a full last row.
    return end === text.length && right - left < this.#width;
  }

  #append(layout) {
    const {row, text, parts} = layout;
    const previous = parts.at(-1);
    const start = previous?.end ?? 0;
    const left = previous?.right ?? 0;
    const {end, right} = this.#boundary(layout, start, left);
    parts.push({row, part: parts.length, start, end, left, right});
    layout.done = this.#isLastPart(text, end, left, right);
  }

  #countParts(row) {
    const cached = this.#layouts.get(row);
    if (cached?.done) return cached.parts.length;
    // Count with a separate iterator so indexing does not retain offscreen segments.
    const layout = this.#newLayout(row);
    if (layout.fixed) return Math.floor(layout.text.length / this.#width) + 1;

    let count = 1;
    let left = 0;
    let {end, right} = this.#boundary(layout, 0, left);
    while (!this.#isLastPart(layout.text, end, left, right)) {
      left = right;
      ({end, right} = this.#boundary(layout, end, left));
      count++;
    }
    return count;
  }

  #buildScreenStarts() {
    const {length} = this.#lines;
    const previous = this.#previousIndex;
    this.#previousIndex = undefined;
    let first = 0;
    let end = length;
    let previousEnd = previous?.lines.length ?? 0;
    if (previous) {
      const common = Math.min(end, previousEnd);
      while (first < common && this.#lines[first].text === previous.lines[first].text) first++;
      if (first === end && first === previousEnd) return previous.starts;
      while (end > first && previousEnd > first && this.#lines[end - 1].text === previous.lines[previousEnd - 1].text) {
        end--;
        previousEnd--;
      }
    }

    const starts = new Uint32Array(length + 1);
    if (first) starts.set(previous.starts.subarray(0, first + 1));
    for (let row = first; row < end; row++) {
      starts[row + 1] = starts[row] + this.#countParts(row);
    }
    if (end < length) {
      const shift = starts[end] - previous.starts[previousEnd];
      for (let row = end + 1; row <= length; row++) {
        previousEnd++;
        starts[row] = previous.starts[previousEnd] + shift;
      }
    }
    return starts;
  }

  get screenRowCount() {
    this.#screenStarts ??= this.#buildScreenStarts();
    return this.#screenStarts.at(-1);
  }

  screenIndex({row, part = 0}) {
    this.#screenStarts ??= this.#buildScreenStarts();
    return this.#screenStarts[row] + part;
  }

  atScreenIndex(index) {
    const target = Math.max(0, Math.min(Math.floor(index), this.screenRowCount - 1));
    let low = 0;
    let high = this.#lines.length;
    while (high - low > 1) {
      const middle = Math.floor((high + low) / 2);
      if (this.#screenStarts[middle] <= target) low = middle;
      else high = middle;
    }
    return this.segment({row: low, part: target - this.#screenStarts[low]});
  }

  #atPart(layout, requested) {
    const part = Math.max(0, requested);
    if (layout.fixed) {
      const last = Math.floor(layout.text.length / this.#width);
      const index = Math.min(part, last);
      const start = index * this.#width;
      const end = Math.min(layout.text.length, start + this.#width);
      return {row: layout.row, part: index, start, end, left: start, right: end};
    }
    while (!layout.done && layout.parts.length <= part) this.#append(layout);
    return layout.parts[Math.min(part, layout.parts.length - 1)];
  }

  segment({row, part = 0}) {
    const index = Math.max(0, Math.min(row, this.#lines.length - 1));
    return this.#atPart(this.#layout(index), part);
  }

  rowAt(row, column) {
    const index = Math.max(0, Math.min(row, this.#lines.length - 1));
    const layout = this.#layout(index);
    const offset = Math.max(0, Math.min(column, layout.text.length));
    if (layout.fixed) return this.#atPart(layout, Math.floor(offset / this.#width));

    while (!layout.done && (!layout.parts.length || layout.parts.at(-1).end <= offset)) {
      this.#append(layout);
    }
    let low = 0;
    let high = layout.parts.length;
    while (high - low > 1) {
      const middle = Math.floor((high + low) / 2);
      if (layout.parts[middle].start <= offset) low = middle;
      else high = middle;
    }
    return layout.parts[low];
  }

  #next(current) {
    const next = this.#atPart(this.#layout(current.row), current.part + 1);
    if (next.part !== current.part) return next;
    if (current.row + 1 < this.#lines.length) return this.segment({row: current.row + 1});
  }

  advance(position, delta) {
    let current = this.segment(position);
    while (delta > 0) {
      const next = this.#next(current);
      if (!next) break;
      current = next;
      delta--;
    }
    while (delta < 0) {
      if (current.part > 0) current = this.segment({row: current.row, part: current.part - 1});
      else if (current.row > 0) current = this.segment({row: current.row - 1, part: Infinity});
      else break;
      delta++;
    }
    return current;
  }

  page(position, count) {
    const rows = [];
    let current = this.segment(position);
    while (current && rows.length < count) {
      rows.push(current);
      if (rows.length < count) current = this.#next(current);
    }
    return rows;
  }

  cellAt(segment, column) {
    const {text, ascii} = this.#layout(segment.row);
    const target = Math.max(segment.start, Math.min(column, segment.end));
    if (ascii) return Math.min(this.#width, target - segment.start);
    const visible = text.slice(segment.start, segment.end);
    let cell = segment.left;
    for (const {index, segment: value} of graphemes.segment(visible)) {
      if (segment.start + index + value.length > target) break;
      cell += cellWidth(value, cell);
    }
    return Math.min(this.#width, cell - segment.left);
  }

  columnAt(segment, cell) {
    const {text, ascii} = this.#layout(segment.row);
    const final = segment.end === text.length && segment.right - segment.left < this.#width;
    const target = Math.max(0, Math.min(this.#width - 1, cell));
    if (ascii) return Math.min(segment.start + target, final ? segment.end : segment.end - 1);
    const visible = text.slice(segment.start, segment.end);
    let column = segment.left;
    let last = segment.start;
    for (const {index, segment: value} of graphemes.segment(visible)) {
      last = segment.start + index;
      column += cellWidth(value, column);
      if (target < column - segment.left) return last;
    }
    return final ? segment.end : last;
  }
}

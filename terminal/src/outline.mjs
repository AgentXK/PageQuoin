import {stat} from 'node:fs/promises';
import path from 'node:path';
import {projectPath, readDocument} from './files.mjs';

const headingLevels = new Map([
  ['part', 0], ['chapter', 1], ['section', 2], ['subsection', 3],
  ['subsubsection', 4], ['paragraph', 5], ['subparagraph', 6],
]);
const verbatimEnvironments = new Set([
  'verbatim', 'verbatim*', 'Verbatim', 'BVerbatim', 'LVerbatim', 'lstlisting',
  'minted', 'comment', 'filecontents', 'filecontents*',
]);
const formattingCommands = new Set([
  'emph', 'textbf', 'textit', 'textup', 'textsl', 'textsc',
  'textrm', 'textsf', 'texttt', 'textnormal', 'underline', 'mbox',
]);

function commentEnd(text, index) {
  const newline = text.indexOf('\n', index + 1);
  return newline < 0 ? text.length : newline + 1;
}

function skipTrivia(text, index) {
  while (index < text.length) {
    if (text[index] === '%') index = commentEnd(text, index);
    else if (/\s/.test(text[index])) index++;
    else break;
  }
  return index;
}

function readGroup(text, start, opening = '{', closing = '}') {
  if (text[start] !== opening) return;
  let depth = 1;
  let braces = 0;
  for (let index = start + 1; index < text.length; index++) {
    const char = text[index];
    if (char === '\\') index++;
    else if (char === '%') index = commentEnd(text, index) - 1;
    else if (opening === '[' && char === '{') braces++;
    else if (opening === '[' && char === '}' && braces > 0) braces--;
    else if (!braces && char === opening) depth++;
    else if (!braces && char === closing && --depth === 0) {
      return {value: text.slice(start + 1, index), end: index + 1};
    }
  }
}

function displayTitle(text) {
  const title = text.replace(/\\(?:[A-Za-z@]+|[\s\S])|%[^\n]*(?:\n|$)|[{}~]/g, match => {
    if (match === '~') return ' ';
    if (!match.startsWith('\\')) return '';
    const command = match.slice(1);
    if (formattingCommands.has(command)) return '';
    if (command === '\\' || /^\s$/.test(command)) return ' ';
    return /^(?:[%#_{}$&]|LaTeX|TeX)$/.test(command) ? command : match;
  });
  return title.replace(/\s+/g, ' ').trim() || 'Untitled';
}

function readInclude(text, index, allowUngrouped) {
  const start = skipTrivia(text, index);
  const group = readGroup(text, start);
  if (group || !allowUngrouped || text[start] === '{') return group;
  const ungrouped = /(?:"([^"\n]*)"|([^\s\\{}#%"]+))/y;
  ungrouped.lastIndex = start;
  const match = ungrouped.exec(text);
  if (!match) return;
  return {value: match[1] ?? match[2], end: ungrouped.lastIndex};
}

function parseOutline(text) {
  const tokens = /\\([A-Za-z@]+|[\s\S])|%[^\n]*/g;
  const entries = [];
  let insideDocument = false;
  let line = 0;
  let newline = text.indexOf('\n');
  for (let match = tokens.exec(text); match; match = tokens.exec(text)) {
    const command = match[1];
    if (command === 'verb' || command === 'lstinline') {
      let start = tokens.lastIndex;
      if (text[start] === '*') start++;
      if (command === 'lstinline') start = readGroup(text, start, '[', ']')?.end ?? start;
      const delimiter = text[start];
      if (delimiter && !/\s/.test(delimiter)) {
        const stop = delimiter === '{' && command === 'lstinline' ? '}' : delimiter;
        const end = text.indexOf(stop, start + 1);
        const endOfLine = commentEnd(text, start);
        tokens.lastIndex = end >= 0 ? Math.min(end + 1, endOfLine) : endOfLine;
      }
    } else if (command === 'begin' || command === 'end') {
      const environment = readGroup(text, skipTrivia(text, tokens.lastIndex));
      if (!environment) continue;
      tokens.lastIndex = environment.end;
      if (command === 'begin' && verbatimEnvironments.has(environment.value)) {
        const closing = '\\end{' + environment.value + '}';
        const end = text.indexOf(closing, tokens.lastIndex);
        tokens.lastIndex = end === -1 ? text.length : end + closing.length;
      } else if (environment.value === 'document') {
        if (command === 'end' && insideDocument) break;
        if (command === 'begin' && !insideDocument) {
          entries.length = 0;
          insideDocument = true;
        }
      }
    } else if (command === 'input' || command === 'include') {
      const argument = readInclude(text, tokens.lastIndex, command === 'input');
      if (!argument) continue;
      tokens.lastIndex = argument.end;
      const name = argument.value.trim();
      if (name && !/[\\{}#%\r\n\0]/.test(name)) entries.push({include: name});
    } else if (headingLevels.has(command)) {
      let start = skipTrivia(text, tokens.lastIndex);
      if (text[start] === '*') start = skipTrivia(text, start + 1);
      if (text[start] === '[') {
        const optional = readGroup(text, start, '[', ']');
        if (!optional) continue;
        start = skipTrivia(text, optional.end);
      }
      const group = readGroup(text, start);
      if (!group) continue;
      tokens.lastIndex = group.end;
      while (newline !== -1 && newline < match.index) {
        line++;
        newline = text.indexOf('\n', newline + 1);
      }
      entries.push({line, level: headingLevels.get(command), title: displayTitle(group.value)});
    }
  }
  return entries;
}

export async function buildOutline(root, startFile, openTexts = new Map()) {
  if (!startFile) return [];
  const canonicalFile = file => projectPath(root, file).catch(() => null);
  const start = await canonicalFile(startFile);
  if (!start) return [];

  const base = path.dirname(start);
  const activeFiles = new Set();
  const parsed = new Map();
  const headings = [];
  let remainingVisits = 512;

  async function resolveInclude(name, parent) {
    const names = path.extname(name) ? [name] : [name + '.tex', name];
    for (const directory of new Set([base, path.dirname(parent)])) {
      for (const candidate of names) {
        const file = await canonicalFile(path.resolve(directory, candidate));
        if (!file) continue;
        if (openTexts.has(file) || (await stat(file).catch(() => null))?.isFile()) return file;
      }
    }
    return null;
  }

  async function visit(file) {
    if (remainingVisits <= 0 || activeFiles.size >= 48 || activeFiles.has(file)) return;
    remainingVisits--;
    activeFiles.add(file);
    try {
      if (!parsed.has(file)) {
        let source = openTexts.get(file);
        if (source === undefined && (await stat(file).catch(() => null))?.isFile()) {
          source = (await readDocument(file).catch(() => null))?.text;
        }
        parsed.set(file, source === undefined ? [] : parseOutline(source));
      }
      for (const entry of parsed.get(file)) {
        if (headings.length >= 8000) break;
        if (entry.include) {
          const child = await resolveInclude(entry.include, file);
          if (child) await visit(child);
        } else {
          headings.push({file, ...entry});
        }
      }
    } finally {
      activeFiles.delete(file);
    }
  }

  await visit(start);
  return headings;
}

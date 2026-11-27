import {stat} from 'node:fs/promises';
import path from 'node:path';
import React, {useEffect, useReducer, useRef} from 'react';
import {Box, Text, measureElement, useApp, useInput, usePaste, useWindowSize} from 'ink';
import open from 'open';
import stringWidth from 'string-width';
import {createAutosave} from './autosave.mjs';
import {cleanBuildIntermediates, compilePDF, createPreview, logLimit, readSharedPDF} from './build.mjs';
import {latexCompletions} from './completion.mjs';
import {EditorBuffer, insertable, lineCells, safeText} from './editor.mjs';
import {findMain, isTeX, listTeXFiles, newDocument, projectEntries, projectPath, readDocument, saveDocument} from './files.mjs';
import {watchProjectFolder} from './folder-watch.mjs';
import {latexTokens} from './latex-syntax.mjs';
import {useMouse} from './mouse.mjs';
import {buildOutline} from './outline.mjs';
import {BuildLogPopup, completionLayout, CompletionPopup, floatingLayout, MainFilePopup} from './popups.mjs';
import {readMainSelection, saveMainSelection, saveSession} from './session.mjs';
import {activeSyntaxColors, palette, syntaxColors} from './theme.mjs';
import {WrappedLines} from './wrap.mjs';

const h = React.createElement;
const wheelRows = 3;
const splitSidebarWidth = 25;
const tabGap = 2;
const outlineDividerBorder = {
  topLeft: '├', top: '─', topRight: '┤', right: '│',
  bottomRight: '┘', bottom: '─', bottomLeft: '└', left: '│',
};
const toolbar = [['r', ' Build '], ['p', ' Open PDF '], ['l', ' Log '], ['clean', ' Clean ']];
const toolbarLabels = toolbar.map(([, label]) => label);
const toolbarWidth = 1 + toolbarLabels.join(' ').length;
const statusMarkers = {accent: '•', success: '✓', warning: '!', error: '!'};
const template = '\\documentclass{article}\n\n\\begin{document}\n\n\\end{document}\n';
const help = [
  'Ctrl+B  Focus files / editor     Enter  Open selected file',
  'Ctrl+D  Focus outline           Enter  Jump to selected heading',
  'Ctrl+O  Open a path              Ctrl+N  New file',
  'Ctrl+G  Next tab                 Click × or Ctrl+W  Close tab',
  'Ctrl+S  Save                     Ctrl+E  Save a copy',
  'Ctrl+C  Copy   Ctrl+X  Cut       Ctrl+V  Paste',
  'Ctrl+F  Find in this file        Ctrl+Z / Ctrl+Y  Undo / redo',
  'Alt+M   Choose main file         Ctrl+T  Set current TeX as main',
  'Ctrl+R  Save all and compile',
  'Ctrl+P  Open PDF in browser      Ctrl+K  Stop build',
  'Alt+K   Clean intermediate build files',
  'Ctrl+L  Build log                Ctrl+Q  Quit',
  'Ctrl+U  Toggle help              Esc  Return to editor',
  'TeX     Type a command, use ↑/↓ to choose and Tab to insert',
  'Mouse   Drag text to select or drag pane dividers to resize',
];

function pointIn(ref, event) {
  if (!ref.current) return null;
  const bounds = measureElement(ref.current);
  const x = event.x - bounds.x;
  const y = event.y - bounds.y;
  return x >= 0 && x < bounds.width && y >= 0 && y < bounds.height ? {x, y} : null;
}

function itemAt(labels, x, gap) {
  let left = 1;
  return labels.findIndex(label => {
    const right = left + stringWidth(label);
    const inside = x >= left && x < right;
    left = right + gap;
    return inside;
  });
}

function visibleTabs(model, columns) {
  const available = columns - 1;
  const items = model.tabs.map((tab, index) => {
    const name = safeText(path.basename(tab.file));
    const active = index === model.active;
    const chrome = 2 + Number(tab.dirty) + 2 * Number(active);
    const labelWidth = Math.max(1, Math.min(24, available - chrome, stringWidth(name)));
    return {tab, index, name, active, labelWidth, width: labelWidth + chrome};
  });
  let offset = Math.max(0, Math.min(model.tabStart, items.length - 1));
  if (!model.tabScrolled && model.active >= 0) {
    offset = Math.min(offset, model.active);
    let width = items.slice(offset, model.active + 1).reduce((sum, item) => sum + item.width + tabGap, -tabGap);
    while (offset < model.active && width > available) width -= items[offset++].width + tabGap;
  }
  model.tabStart = offset;

  const result = [];
  let left = 1;
  for (let index = offset; index < items.length; index++) {
    const item = items[index];
    const right = left + item.width;
    if (right > columns) break;
    result.push({...item, left, right});
    left = right + tabGap;
  }
  return result;
}

function scrollOffset(offset, count, visible) {
  return Math.max(0, Math.min(count - visible, offset));
}

function sidebarWidth(size, columns) {
  return Math.max(16, Math.min(size, columns - 36));
}

function revealIndex(index, offset, visible) {
  return Math.max(index - visible + 1, Math.min(offset, index));
}

function gutterWidth(tab) {
  return Math.max(3, String(tab.lines.length).length) + 3;
}

function sourceColumns(tab, width) {
  return Math.max(1, width - gutterWidth(tab) - 2);
}

const editorLayouts = new WeakMap();
const systemClipboard = () => import('clipboardy').then(module => module.default);

function editorLayout(tab, width) {
  const columns = sourceColumns(tab, width);
  const lines = tab.lines;
  const cached = editorLayouts.get(tab);
  if (cached?.lines === lines && cached.columns === columns) return cached.layout;
  const layout = new WrappedLines(lines, columns);
  editorLayouts.set(tab, {lines, columns, layout});
  return layout;
}

function compareRows(first, second) {
  return first.row - second.row || first.part - second.part;
}

function setViewport(tab, anchor) {
  tab.top = anchor.row;
  tab.wrapStart = anchor.start;
}

function editorViewport(tab, width, rows) {
  const {row, column} = tab.position;
  const wrap = editorLayout(tab, width);
  const cursorRow = wrap.rowAt(row, column);
  let first = wrap.rowAt(tab.top, tab.wrapStart);
  if (!tab.scrollDetached) {
    if (compareRows(cursorRow, first) < 0) first = cursorRow;
    else if (compareRows(cursorRow, wrap.advance(first, rows - 1)) > 0) {
      first = wrap.advance(cursorRow, 1 - rows);
    }
  }
  let page = wrap.page(first, rows);
  if (page.length < rows) {
    first = wrap.advance(first, page.length - rows);
    page = wrap.page(first, rows);
  }
  setViewport(tab, first);
  return {wrap, cursorRow, page, column};
}

export function App({root, initial, mainFile, initialPDF, entries, session, autosaveDelay = 1000, removedAtOnOpen}) {
  const {exit} = useApp();
  const {columns, rows} = useWindowSize();
  const [, refresh] = useReducer(count => count + 1, 0);
  const tabsPanel = useRef(null);
  const filesPanel = useRef(null);
  const outlinePanel = useRef(null);
  const editorPanel = useRef(null);
  const completionPanel = useRef(null);
  const logPanel = useRef(null);
  const logClose = useRef(null);
  const toolbarPanel = useRef(null);
  const mainButton = useRef(null);
  const mainPanel = useRef(null);
  const mainClose = useRef(null);
  const state = useRef(null);
  if (!state.current) {
    state.current = {
      root, folder: root, entries, selected: 0, fileTop: 0, tabs: [], active: -1, main: mainFile, focus: 'files',
      tabStart: 0, tabScrolled: false,
      status: 'Select a file or press Ctrl+N to create one.', statusTone: 'muted', busy: false, prompt: null, build: null,
      log: '', logTop: 0, logVisible: false, logFocused: false,
      preview: createPreview(), pdf: initialPDF ?? null, url: null,
      outline: [], outlineSource: null, outlineDepth: 0, outlineSelected: 0, outlineTop: 0, outlineRevision: 0,
      ready: !session && !initial, quitting: false, sessionWrite: Promise.resolve(), savedWorkspaceKey: null,
      drag: null, resize: null, sidebarWidth: splitSidebarWidth, fileFraction: null,
      completion: null, mainPicker: null, internalClipboard: '', useInternalClipboard: false,
    };
    state.current.autosave = createAutosave({
      delay: autosaveDelay,
      async write(tab) {
        const text = tab.text;
        tab.snapshot = await saveDocument(root, tab.file, text, tab.snapshot);
      },
      onSaved(tab) {
        const current = state.current;
        if (current.quitting || !current.tabs.includes(tab)) return;
        if (!tab.dirty && !current.build && !current.prompt) status('Autosaved · ' + path.basename(tab.file), 'success');
        else refresh();
      },
      onError(tab, error) {
        const current = state.current;
        if (current.quitting || !current.tabs.includes(tab)) return;
        status('Autosave failed · ' + path.basename(tab.file) + ' · ' + error.message, 'error');
      },
    });
  }
  const model = state.current;
  const active = () => model.tabs[model.active];
  const wide = columns >= 72;
  const sideWidth = wide ? sidebarWidth(model.sidebarWidth, columns) : columns;
  const editorWidth = wide ? columns - sideWidth : columns;
  const shownRows = Math.max(1, rows - 6 - Number(Boolean(model.prompt)) - Number(Boolean(model.url)));
  const workHeight = shownRows + 3;
  const {main: mainFrame, log: logFrame} = floatingLayout(columns, workHeight, model.mainPicker?.anchor);
  const pickerRows = mainFrame.rows;
  const splitSidebar = shownRows >= 7;
  // The split sidebar adds a second header and one divider row.
  const sidebarRows = shownRows - 2;
  const preferredFiles = model.fileFraction === null
    ? Math.min(model.entries.length, Math.ceil(sidebarRows * 0.6))
    : Math.round(sidebarRows * model.fileFraction);
  const fileRows = splitSidebar ? Math.max(1, Math.min(sidebarRows - 1, preferredFiles)) : shownRows;
  const outlineRows = splitSidebar ? sidebarRows - fileRows : shownRows;
  const currentTab = active();
  const outlineSource = model.main ?? (currentTab && isTeX(currentTab.file) ? currentTab.file : null);
  const sidebarFocused = model.focus === 'files' || model.focus === 'outline';
  const showEditor = model.focus !== 'help' && (wide || !sidebarFocused);
  const viewport = showEditor && currentTab ? editorViewport(currentTab, editorWidth, shownRows) : null;
  const activeCompletion = () => !model.prompt && !model.mainPicker && !model.logFocused &&
    model.focus === 'editor' && model.completion?.tab === active() ? model.completion : null;
  const completion = activeCompletion();
  const completionFrame = frameForCompletion(completion, viewport);
  const tabs = visibleTabs(model, columns);

  function frameForCompletion(suggestion, layout) {
    if (!suggestion || !layout) return null;
    const {wrap, cursorRow, page, column} = layout;
    const screenRow = page.findIndex(segment => compareRows(segment, cursorRow) === 0);
    if (screenRow < 0) return null;
    const {tab, items, index} = suggestion;
    const cell = Math.min(wrap.cellAt(cursorRow, column), sourceColumns(tab, editorWidth) - 1);
    return completionLayout({columns, height: workHeight,
      cursorX: (wide ? sideWidth : 0) + 1 + gutterWidth(tab) + cell, cursorY: 2 + screenRow, items, index});
  }

  function relative(file) {
    return file ? path.relative(root, file).split(path.sep).join('/') : null;
  }

  async function chooseMain(file) {
    if (model.build) throw new Error('Stop the current build with Ctrl+K before changing the main file.');
    const chosen = file === null ? null : await projectPath(root, file);
    if (chosen && (!isTeX(chosen) || !(await stat(chosen)).isFile())) {
      throw new Error('Select a .tex or .ltx file.');
    }
    const next = chosen ?? await findMain(root);
    await saveMainSelection(root, relative(chosen));
    const pdf = await readSharedPDF(root, next);
    if (next !== model.main) {
      model.pdf = pdf;
      model.url = null;
    } else if (pdf) model.pdf = pdf;
    model.main = next;
    status(chosen ? 'Main · ' + relative(chosen) : 'Main · Automatic' + (next ? ' · ' + relative(next) : ' · No main file found'));
  }

  function toggleMainPicker() {
    model.completion = null;
    if (model.mainPicker) {
      model.mainPicker = null;
      refresh();
      return;
    }
    if (model.build) {
      status('Stop the current build with Ctrl+K before changing the main file.', 'warning');
      return;
    }
    const anchor = mainButton.current ? measureElement(mainButton.current).x : undefined;
    void operation(async () => {
      const [files, detected, stored] = await Promise.all([listTeXFiles(root), findMain(root), readMainSelection(root)]);
      const activeFile = stored === undefined
        ? (model.main === detected ? null : model.main)
        : (stored === null ? null : path.resolve(root, stored));
      const options = [
        {file: null, text: 'Automatic' + (detected ? ' · ' + relative(detected) : '')},
        ...files.map(file => ({file, text: relative(file)})),
      ];
      const selected = Math.max(0, options.findIndex(option => option.file === activeFile));
      model.mainPicker = {options, activeFile, query: '', selected, offset: revealIndex(selected, 0, pickerRows), anchor};
    });
  }

  function visibleMainOptions(picker) {
    const query = picker.query.toLowerCase().trim();
    return query ? picker.options.filter(option => option.text.toLowerCase().includes(query)) : picker.options;
  }

  function applyMainOption(option) {
    if (!option) return;
    void operation(async () => {
      await chooseMain(option.file);
      model.mainPicker = null;
    });
  }

  function filterMainOptions(query) {
    model.mainPicker.query = query;
    model.mainPicker.selected = 0;
    model.mainPicker.offset = 0;
    refresh();
  }

  function handleMainPicker(input, key) {
    const picker = model.mainPicker;
    const options = visibleMainOptions(picker);
    if (key.escape) {
      model.mainPicker = null;
    } else if (key.ctrl && ['q', 'c'].includes(input.toLowerCase())) {
      model.mainPicker = null;
      quit();
    } else if (key.return) {
      applyMainOption(options[picker.selected]);
    } else if (key.upArrow || key.downArrow || key.pageUp || key.pageDown) {
      const step = key.upArrow ? -1 : key.downArrow ? 1 : key.pageUp ? -pickerRows : pickerRows;
      picker.selected = scrollOffset(picker.selected + step, options.length, 1);
      picker.offset = revealIndex(picker.selected, picker.offset, pickerRows);
    } else if (key.backspace) {
      filterMainOptions(Array.from(picker.query).slice(0, -1).join(''));
    } else if (!key.ctrl && !key.meta && !key.tab) {
      const text = insertable(input).replace(/[\n\t]/g, '');
      if (text) filterMainOptions(picker.query + text);
    }
    refresh();
  }

  function snapshot() {
    return {
      root, main: relative(model.main), active: relative(active()?.file), pdf: relative(model.pdf),
      tabs: model.tabs.map(({file, cursor, top, wrapStart}) => ({file: relative(file), cursor, top, left: 0, wrapStart})),
    };
  }

  function checkpoint() {
    const current = snapshot();
    const key = JSON.stringify(current);
    model.sessionWrite = model.sessionWrite.catch(() => {}).then(async () => {
      if (model.savedWorkspaceKey === key) return;
      await saveSession(current, {removedAtOnOpen});
      model.savedWorkspaceKey = key;
    });
    return model.sessionWrite;
  }

  function status(message, tone = 'muted') {
    model.status = message;
    model.statusTone = tone;
    refresh();
  }

  async function operation(work) {
    if (model.busy) return;
    model.busy = true;
    refresh();
    try { await work(); }
    catch (error) { status(error.message, 'error'); }
    finally {
      model.busy = false;
      refresh();
    }
  }

  async function openFile(input, savedPosition) {
    const file = await projectPath(model.root, input);
    const alreadyOpen = model.tabs.findIndex(tab => tab.file === file);
    if (alreadyOpen >= 0) model.active = alreadyOpen;
    else {
      const snapshot = await readDocument(file);
      const tab = new EditorBuffer(file, snapshot);
      if (savedPosition) tab.restorePosition(savedPosition);
      model.tabs.push(tab);
      model.active = model.tabs.length - 1;
      if (isTeX(file)) model.outlineRevision++;
    }
    model.focus = 'editor';
    model.tabScrolled = false;
    model.logFocused = false;
    if (!savedPosition) await revealFile(file);
    if (active().snapshot.mixedEndings) status('Mixed line endings · Ctrl+E to save a normalized copy', 'warning');
    else status('Ready');
  }

  async function restoreWorkspace() {
    let unavailable = 0;
    for (const tab of session.tabs) {
      if (tab.desktopOnly) {
        unavailable++;
        continue;
      }
      try {
        await openFile(tab.file, tab);
      } catch {
        unavailable++;
      }
    }
    const selected = model.tabs.findIndex(tab => relative(tab.file) === session.active);
    if (selected >= 0) model.active = selected;
    else if (!model.tabs.length && unavailable && initial) await openFile(initial).catch(() => {});
    if (active()) await revealFile(active().file);

    if (!model.pdf && (session.main === null || session.main === relative(model.main)) &&
        session.pdf?.startsWith('.pagequoin-terminal/') && /\.pdf$/i.test(session.pdf)) {
      try {
        const pdf = await projectPath(root, session.pdf);
        if (relative(pdf) === session.pdf && (await stat(pdf)).isFile()) model.pdf = pdf;
      } catch {
        // The project can still be edited if the old build was cleaned.
      }
    }
    const message = unavailable ? 'Restored project · Some tabs are unavailable' : 'Restored project';
    status(model.pdf ? message + ' · Ctrl+P to open the last PDF' : message);
  }

  async function browse(folder) {
    const list = await projectEntries(model.root, folder);
    model.folder = await projectPath(model.root, folder);
    model.entries = list;
    model.selected = 0;
    model.fileTop = 0;
    refresh();
  }

  async function revealFile(file) {
    const parent = path.dirname(file);
    if (parent !== model.folder) await browse(parent);
    const index = model.entries.findIndex(entry => entry.path === file);
    if (index < 0) return;
    model.selected = index;
    model.fileTop = revealIndex(index, model.fileTop, fileRows);
  }

  function openEntry(index) {
    const entry = model.entries[index];
    if (!entry) return;
    model.selected = index;
    model.focus = 'files';
    void operation(() => entry.directory ? browse(entry.path) : openFile(entry.path));
  }

  function selectTab(index) {
    if (index < 0 || !model.tabs.length) return;
    model.active = index;
    model.tabScrolled = false;
    model.focus = 'editor';
    model.logFocused = false;
    void operation(() => revealFile(active().file));
  }

  function jumpToHeading(index) {
    const heading = model.outlineSource === outlineSource && model.outline[index];
    if (!heading) return;
    model.outlineSelected = index;
    void operation(async () => {
      await openFile(heading.file);
      const tab = active();
      tab.placeCursor(heading.line, 0);
      tab.top = Math.max(0, tab.position.row - 2);
      tab.wrapStart = 0;
      tab.scrollDetached = false;
    });
  }

  function editTab(tab, edit) {
    const before = tab.text;
    edit();
    if (before === tab.text) return false;
    if (isTeX(tab.file)) model.outlineRevision++;
    model.autosave.schedule(tab);
    return true;
  }

  function suggest(tab) {
    model.completion = null;
    if (!tab || !isTeX(tab.file) || tab.selection) return;
    const {row, column} = tab.position;
    const line = tab.lines[row];
    const result = latexCompletions(line.text, column);
    if (result?.items.length) {
      model.completion = {...result, tab, index: 0, start: line.start + result.start, end: line.start + result.end};
    }
  }

  function applyCompletion({tab, start, end, items}, index) {
    model.completion = null;
    tab.scrollDetached = false;
    editTab(tab, () => tab.replace(start, end, items[index].text));
  }

  async function copySelection(tab, cut) {
    const text = tab.selectedText;
    if (!text) return;
    model.internalClipboard = text;
    try {
      await (await systemClipboard()).write(text);
      model.useInternalClipboard = false;
    } catch {
      model.useInternalClipboard = true;
    }
    if (cut) editTab(tab, () => tab.deleteSelection());
    status((cut ? 'Cut selection' : 'Copied selection') +
      (model.useInternalClipboard ? ' · PageQuoin clipboard' : ''));
  }

  async function pasteClipboard(tab) {
    let text = model.internalClipboard;
    if (!model.useInternalClipboard) {
      try { text = await (await systemClipboard()).read(); }
      catch { /* Retain the local copy when system clipboard access is unavailable. */ }
    }
    if (!text) return;
    tab.scrollDetached = false;
    editTab(tab, () => tab.insertText(insertable(text)));
  }

  function placeEditorCursor(tab, point, extend = false) {
    const wrap = editorLayout(tab, editorWidth);
    let first = wrap.rowAt(tab.top, tab.wrapStart);
    const row = point.y - 2;
    if (extend && (row < 0 || row >= shownRows)) {
      first = wrap.advance(first, row < 0 ? -1 : 1);
      setViewport(tab, first);
    }
    const displayRow = Math.max(0, Math.min(shownRows - 1, row));
    const segment = wrap.page(first, displayRow + 1)[displayRow];
    const cell = Math.max(0, point.x - 1 - gutterWidth(tab));
    if (segment) tab.placeCursorAt(segment.row, wrap.columnAt(segment, cell), extend);
    else tab.placeCursorAt(tab.lines.length, 0, extend);
    tab.scrollDetached = false;
  }

  function adjustLog(shift) {
    model.logTop = scrollOffset(model.logTop + shift, model.log.split('\n').length, logFrame.rows);
  }

  function closeLog() {
    model.logVisible = false;
    model.logFocused = false;
  }

  function resizeWorkspace(gesture, event) {
    if (gesture.axis === 'width') {
      if (wide) model.sidebarWidth = sidebarWidth(gesture.size + event.x - gesture.start, columns);
    } else if (splitSidebar) {
      const height = Math.max(1, Math.min(sidebarRows - 1, gesture.size + event.y - gesture.start));
      if (event.y === gesture.start && model.fileFraction === null) return;
      model.fileFraction = height / sidebarRows;
      if (model.focus === 'files') model.fileTop = revealIndex(model.selected, model.fileTop, height);
      if (model.focus === 'outline') model.outlineTop = revealIndex(model.outlineSelected, model.outlineTop, sidebarRows - height);
    }
  }

  async function showPDF() {
    model.pdf = await readSharedPDF(root, model.main) ?? model.pdf;
    if (model.pdf && !(await stat(model.pdf).catch(() => null))?.isFile()) {
      model.pdf = null;
      model.url = null;
    }
    if (!model.pdf) {
      status('Compile a project first with Ctrl+R.', 'warning');
      return;
    }
    const url = await model.preview.url(model.pdf);
    model.url = url;
    try {
      await open(url, {wait: false});
      status('PDF ready in the browser · Ctrl+P to reopen', 'success');
    } catch {
      status('Open the local preview URL shown below in your browser.');
    }
  }

  function build() {
    if (model.build) {
      status('A build is already running · Ctrl+K to stop', 'warning');
      return;
    }
    void operation(async () => {
      if (!model.main) throw new Error('Open a TeX file and press Ctrl+T to set the main document.');
      const main = model.main;
      for (const file of model.tabs) await model.autosave.save(file);
      const controller = new AbortController();
      model.build = controller;
      model.log = '';
      model.logTop = 0;
      let exported;
      status('Compiling ' + path.relative(model.root, main) + '…', 'accent');
      void compilePDF(model.root, main, {
        signal: controller.signal,
        onExport(result) { exported = result; },
        onOutput(chunk) {
          model.log = (model.log + chunk).slice(-logLimit);
          model.logTop = scrollOffset(Infinity, model.log.split('\n').length, logFrame.rows);
          refresh();
        },
      }).then(async pdf => {
        if (model.quitting) return;
        model.pdf = pdf;
        model.url = await model.preview.url(pdf);
        if (exported?.error) {
          status('Preview ready · Could not write ' + relative(exported.file) + ' · ' + exported.error.message, 'warning');
        } else {
          status(exported ? 'Build complete · ' + relative(exported.file) : 'Build complete · Open PDF or Ctrl+P', 'success');
        }
      }).catch(error => {
        if (!controller.signal.aborted) {
          model.logVisible = true;
          model.logFocused = true;
        }
        status(error.message, controller.signal.aborted ? 'muted' : 'error');
      }).finally(() => {
        model.build = null;
        refresh();
      });
    });
  }

  function cleanBuild() {
    if (model.build) {
      status('Stop the current build with Ctrl+K before cleaning.', 'warning');
      return;
    }
    void operation(async () => {
      const count = await cleanBuildIntermediates(root);
      status(count ? 'Cleaned ' + count + ' intermediate ' + (count === 1 ? 'file' : 'files') : 'No intermediate files to clean.',
        count ? 'success' : 'muted');
    });
  }

  function confirm(message, action, cancel) {
    model.prompt = {label: message, confirm: action, cancel, text: ''};
    refresh();
  }

  function prompt(label, submit, text = '') {
    model.prompt = {label, submit, text};
    refresh();
  }

  function closeTab(tab = active()) {
    if (!tab) return;
    model.autosave.cancel(tab);
    const close = () => void operation(async () => {
      await model.autosave.idle();
      const index = model.tabs.indexOf(tab);
      if (index < 0) return;
      const previous = active();
      if (isTeX(tab.file)) model.outlineRevision++;
      model.tabs.splice(index, 1);
      if (index < model.tabStart) model.tabStart--;
      model.active = previous === tab ? Math.min(index, model.tabs.length - 1) : model.tabs.indexOf(previous);
      if (previous === tab) model.tabScrolled = false;
      if (!active()) model.focus = 'files';
      else if (previous === tab) await revealFile(active().file);
    });
    if (tab.dirty) confirm('Discard unsaved changes in ' + safeText(path.basename(tab.file)) + '?', close,
      () => model.autosave.schedule(tab));
    else close();
  }

  function quit() {
    const finish = () => {
      model.quitting = true;
      model.build?.abort();
      model.autosave.dispose();
      void Promise.allSettled([checkpoint(), model.preview.close(), model.autosave.idle()]).then(([saved]) => {
        exit(saved.status === 'rejected' ? 'Could not save the session. ' + saved.reason.message : undefined);
      });
    };
    const dirty = model.tabs.filter(tab => tab.dirty);
    if (dirty.length) {
      for (const tab of dirty) model.autosave.cancel(tab);
      confirm('Quit and discard unsaved edits?', finish, () => {
        for (const tab of dirty) model.autosave.schedule(tab);
      });
    } else finish();
  }

  function handlePrompt(input, key) {
    const prompt = model.prompt;
    if (key.escape || (key.ctrl && ['q', 'c'].includes(input))) {
      model.prompt = null;
      prompt.cancel?.();
    } else if (prompt.confirm) {
      if (input.toLowerCase() === 'y') {
        model.prompt = null;
        prompt.confirm();
      } else if (input.toLowerCase() === 'n' || key.return) {
        model.prompt = null;
        prompt.cancel?.();
      }
    } else if (key.return) {
      const text = prompt.text;
      model.prompt = null;
      void operation(() => prompt.submit(text));
    } else if (key.backspace) {
      prompt.text = Array.from(prompt.text).slice(0, -1).join('');
    } else if (!key.ctrl && !key.meta) {
      prompt.text += insertable(input).replace(/[\n\t]/g, '');
    }
    refresh();
  }

  function shortcut(input) {
    model.completion = null;
    const tab = active();
    switch (input) {
      case 'b':
        model.logFocused = false;
        model.focus = model.focus === 'files' && active() ? 'editor' : 'files';
        break;
      case 'd':
        model.logFocused = false;
        model.focus = model.focus === 'outline' ? (active() ? 'editor' : 'files') : 'outline';
        break;
      case 'o': prompt('Open path', openFile); break;
      case 'n':
        prompt('New file path', async input => {
          const file = await newDocument(model.root, input, path.basename(input) === 'main.tex' ? template : '');
          await browse(path.dirname(file));
          await openFile(file);
          if (!model.main && isTeX(file)) model.main = file;
        }, model.tabs.length === 0 ? 'main.tex' : '');
        break;
      case 's':
        if (tab) void operation(async () => { await model.autosave.save(tab); status('Saved', 'success'); });
        break;
      case 'c':
        if (!model.logFocused && model.focus === 'editor' && tab) {
          if (tab.selection) void operation(() => copySelection(tab, false));
        } else quit();
        break;
      case 'x':
        if (!model.logFocused && model.focus === 'editor' && tab?.selection) void operation(() => copySelection(tab, true));
        break;
      case 'v':
        if (!model.logFocused && model.focus === 'editor' && tab) void operation(() => pasteClipboard(tab));
        break;
      case ' ':
        if (!model.logFocused && model.focus === 'editor') suggest(tab);
        break;
      case 'e':
        if (active()) prompt('Save a copy as', async input => {
          const file = await newDocument(model.root, input, active().text);
          await browse(path.dirname(file));
          await openFile(file);
        });
        break;
      case 'g':
        if (model.tabs.length) selectTab((model.active + 1) % model.tabs.length);
        break;
      case 'f':
        if (active()) prompt('Find text', query => {
          model.focus = 'editor';
          model.logFocused = false;
          active().scrollDetached = false;
          status(query && active().find(query) ? 'Match found' : 'No match');
        });
        break;
      case 'w': closeTab(); break;
      case 'z':
      case 'y': {
        const tab = active();
        if (!model.logFocused && model.focus === 'editor' && tab) {
          tab.scrollDetached = false;
          editTab(tab, () => input === 'z' ? tab.undo() : tab.redo());
        }
        break;
      }
      case 't': {
        const file = model.focus === 'files' ? model.entries[model.selected]?.path : active()?.file;
        if (file && isTeX(file)) void operation(() => chooseMain(file));
        else toggleMainPicker();
        break;
      }
      case 'r': build(); break;
      case 'k': if (model.build) { model.build.abort(); status('Stopping Tectonic…', 'accent'); } break;
      case 'clean': cleanBuild(); break;
      case 'p': void operation(showPDF); break;
      case 'l':
        if (model.logVisible) closeLog();
        else { model.logVisible = true; model.logFocused = true; }
        break;
      case 'u':
        model.logFocused = false;
        model.focus = model.focus === 'help' ? (active() ? 'editor' : 'files') : 'help';
        break;
      case 'q':
        quit();
        break;
    }
    refresh();
  }

  useEffect(() => {
    if (session || initial) {
      void operation(async () => {
        try {
          if (session) await restoreWorkspace();
          else await openFile(initial);
        } finally {
          model.ready = true;
        }
      });
    }
    return () => {
      model.autosave.dispose();
      model.build?.abort();
      void model.preview.close();
    };
  }, []);

  useEffect(() => {
    const folder = model.folder;
    let generation = 0;
    let disposed = false;

    const refreshEntries = async () => {
      const request = ++generation;
      const previous = model.entries;
      const isCurrent = () => !disposed && !model.quitting && request === generation &&
        model.folder === folder && model.entries === previous;
      try {
        let directory = folder;
        const list = await projectEntries(root, folder).catch(error => {
          if (folder === root || !['ENOENT', 'ENOTDIR'].includes(error.code)) throw error;
          directory = root;
          return projectEntries(root, root);
        });
        if (!isCurrent()) return;
        if (directory === folder && list.length === previous.length &&
            list.every((entry, index) => entry.path === previous[index].path && entry.directory === previous[index].directory)) return;
        model.folder = directory;
        model.entries = list;
        if (directory === folder) {
          const selected = list.findIndex(entry => entry.path === previous[model.selected]?.path);
          const first = list.findIndex(entry => entry.path === previous[model.fileTop]?.path);
          model.selected = selected >= 0 ? selected : scrollOffset(model.selected, list.length, 1);
          if (model.fileTop > 0 && first >= 0) model.fileTop = first;
        } else {
          model.selected = 0;
          model.fileTop = 0;
          model.status = 'Folder moved or removed · Returned to project';
          model.statusTone = 'warning';
        }
        refresh();
      } catch (error) {
        if (!isCurrent()) return;
        const message = 'Files · ' + error.message;
        if (model.status !== message) status(message, 'error');
      }
    };
    const stop = watchProjectFolder(folder, () => void refreshEntries());
    return () => {
      disposed = true;
      stop();
    };
  }, [root, model.folder]);

  const sessionKey = JSON.stringify(snapshot());
  useEffect(() => {
    if (!model.ready) return;
    const timer = setTimeout(() => {
      if (!model.quitting) void checkpoint().catch(() => {});
    }, 600);
    return () => clearTimeout(timer);
  }, [model.ready, sessionKey]);

  useEffect(() => {
    if (!model.ready) return;
    let stale = false;
    const timer = setTimeout(async () => {
      const openTexts = new Map(model.tabs.filter(tab => isTeX(tab.file)).map(tab => [tab.file, tab.text]));
      const headings = await buildOutline(root, outlineSource, openTexts).catch(() => []);
      if (stale || model.quitting) return;
      if (model.outlineSource !== outlineSource) {
        model.outlineTop = 0;
        model.outlineSelected = 0;
      }
      model.outline = headings;
      model.outlineSource = outlineSource;
      model.outlineDepth = headings.reduce((depth, heading) => Math.min(depth, heading.level), Infinity);
      model.outlineSelected = Math.max(0, Math.min(model.outlineSelected, headings.length - 1));
      refresh();
    }, 250);
    return () => {
      stale = true;
      clearTimeout(timer);
    };
  }, [model.ready, outlineSource, model.outlineRevision]);

  usePaste(text => {
    if (model.busy || model.quitting) return;
    model.completion = null;
    model.drag = null;
    model.resize = null;
    if (model.mainPicker) filterMainOptions(model.mainPicker.query + insertable(text).replace(/[\n\t]/g, ''));
    else if (model.prompt?.submit) model.prompt.text += insertable(text).replace(/[\n\t]/g, '');
    else if (!model.prompt && !model.logFocused && model.focus === 'editor' && active()) {
      const tab = active();
      tab.scrollDetached = false;
      editTab(tab, () => tab.insertText(insertable(text)));
    }
    refresh();
  });

  useInput((input, key) => {
    if (key.eventType === 'release' || model.busy || model.quitting) return;
    model.drag = null;
    model.resize = null;
    const suggestion = activeCompletion();
    if (model.prompt) {
      handlePrompt(input, key);
      return;
    }
    if (key.meta && input.toLowerCase() === 'm') {
      toggleMainPicker();
      return;
    }
    if (model.mainPicker) {
      handleMainPicker(input, key);
      return;
    }
    if (key.meta && input.toLowerCase() === 'k') {
      shortcut('clean');
      return;
    }
    if (key.ctrl) {
      shortcut(input.toLowerCase());
      return;
    }
    if (model.logFocused) {
      if (key.escape) closeLog();
      else {
        const shift = key.upArrow ? -1 : key.downArrow ? 1 : key.pageUp ? -logFrame.rows :
          key.pageDown ? logFrame.rows : key.home ? -Infinity : key.end ? Infinity : 0;
        adjustLog(shift);
      }
      refresh();
      return;
    }
    if (key.escape) {
      if (!suggestion) active()?.clearSelection();
      model.completion = null;
      model.focus = active() ? 'editor' : 'files';
      refresh();
      return;
    }
    if (model.focus === 'files') {
      if (key.upArrow || key.downArrow) {
        model.selected = Math.max(0, Math.min(model.entries.length - 1, model.selected + (key.upArrow ? -1 : 1)));
        model.fileTop = revealIndex(model.selected, model.fileTop, fileRows);
      } else if (key.return || key.rightArrow) {
        openEntry(model.selected);
      } else if (key.leftArrow && model.root !== model.folder) {
        void operation(() => browse(path.dirname(model.folder)));
      }
    } else if (model.focus === 'outline') {
      if ((key.upArrow || key.downArrow) && model.outlineSource === outlineSource) {
        model.outlineSelected = Math.max(0, Math.min(model.outline.length - 1,
          model.outlineSelected + (key.upArrow ? -1 : 1)));
        model.outlineTop = revealIndex(model.outlineSelected, model.outlineTop, outlineRows);
      } else if (key.return || key.rightArrow) jumpToHeading(model.outlineSelected);
    } else if (model.focus === 'editor' && active()) {
      const tab = active();
      const choosing = suggestion && !key.shift && (key.upArrow || key.downArrow || key.tab);
      const frame = choosing && (suggestion === completion ? completionFrame
        : frameForCompletion(suggestion, editorViewport(tab, editorWidth, shownRows)));
      if (frame) {
        if (key.tab) applyCompletion(suggestion, suggestion.index);
        else {
          const count = suggestion.items.length;
          suggestion.index = (suggestion.index + (key.upArrow ? -1 : 1) + count) % count;
        }
      } else {
        tab.scrollDetached = false;
        model.completion = null;
        const changed = editTab(tab, () => tab.key(input, key, shownRows, editorLayout(tab, editorWidth)));
        if (changed && !key.return && !key.tab) suggest(tab);
      }
    }
    refresh();
  });

  useMouse(event => {
    const dragging = model.drag;
    const resize = model.resize;
    if (event.type === 'click' || event.type === 'release') {
      model.drag = null;
      model.resize = null;
    }
    if (model.busy || model.quitting || model.prompt) return;
    if (resize && (event.type === 'drag' || event.type === 'release')) {
      resizeWorkspace(resize, event);
      refresh();
      return;
    }
    if (event.type === 'click' && pointIn(mainButton, event)) {
      toggleMainPicker();
      return;
    }
    if (model.mainPicker) {
      const picker = model.mainPicker;
      const point = pointIn(mainPanel, event);
      if (event.type === 'click' && (!point || pointIn(mainClose, event))) {
        model.mainPicker = null;
        refresh();
        return;
      }
      if (!point) return;
      const options = visibleMainOptions(picker);
      if (event.type === 'wheel') {
        picker.offset = scrollOffset(picker.offset + event.delta * wheelRows, options.length, pickerRows);
        refresh();
      } else if (event.type === 'click') {
        const row = point.y - 2 - Number(mainFrame.showFilter);
        const index = picker.offset + row;
        if (row >= 0 && row < pickerRows && options[index]) {
          picker.selected = index;
          applyMainOption(options[index]);
        }
      }
      return;
    }
    const tab = active();
    if (event.type === 'drag' || event.type === 'release') {
      if (!dragging || dragging.tab !== tab || !editorPanel.current ||
          (event.type === 'release' && !dragging.moved && dragging.x === event.x && dragging.y === event.y)) return;
      dragging.moved = true;
      const bounds = measureElement(editorPanel.current);
      placeEditorCursor(tab, {x: event.x - bounds.x, y: event.y - bounds.y}, true);
      refresh();
      return;
    }
    const completionPoint = completionFrame && completion === activeCompletion() && pointIn(completionPanel, event);
    if (completionPoint) {
      const row = completionPoint.y - 1;
      if (event.type === 'click' && row >= 0 && row < completionFrame.rows &&
          completionPoint.x > 0 && completionPoint.x < completionFrame.width - 1) {
        applyCompletion(completion, completionFrame.offset + row);
      } else if (event.type === 'wheel') {
        completion.index = Math.max(0, Math.min(completion.items.length - 1, completion.index + event.delta));
      }
      refresh();
      return;
    }
    if (model.logVisible && pointIn(logPanel, event)) {
      if (event.type === 'wheel') adjustLog(event.delta * wheelRows);
      else if (event.type === 'click') {
        if (pointIn(logClose, event)) closeLog();
        else {
          model.completion = null;
          model.logFocused = true;
        }
      }
      refresh();
      return;
    }
    const filePoint = pointIn(filesPanel, event);
    const outlinePoint = pointIn(outlinePanel, event);
    const editorPoint = pointIn(editorPanel, event);
    const tabsPoint = pointIn(tabsPanel, event);
    if (event.type === 'wheel') {
      const shift = event.delta * wheelRows;
      if (tabsPoint && model.tabs.length > 1) {
        model.tabScrolled = true;
        model.tabStart = scrollOffset(model.tabStart + event.delta, model.tabs.length, 1);
      } else if (filePoint) model.fileTop = scrollOffset(model.fileTop + shift, model.entries.length, fileRows);
      else if (outlinePoint && model.outlineSource === outlineSource) {
        model.outlineTop = scrollOffset(model.outlineTop + shift, model.outline.length, outlineRows);
      }
      else if (editorPoint && tab) {
        model.completion = null;
        const wrap = editorLayout(tab, editorWidth);
        tab.scrollDetached = true;
        setViewport(tab, wrap.advance(wrap.rowAt(tab.top, tab.wrapStart), shift));
      } else return;
    } else {
      model.completion = null;
      model.logFocused = false;
      const toolbarPoint = pointIn(toolbarPanel, event);
      const onColumnDivider = wide && (
        (event.x === sideWidth - 1 && (filePoint || outlinePoint)) || (event.x === sideWidth && editorPoint)
      );
      if (onColumnDivider) model.resize = {axis: 'width', start: event.x, size: sideWidth};
      else if (splitSidebar && outlinePoint?.y === 0) {
        model.resize = {axis: 'files', start: event.y, size: fileRows};
      } else if (tabsPoint) {
        const entry = tabs.find(item => tabsPoint.x >= item.left && tabsPoint.x < item.right);
        if (entry) {
          if (tabsPoint.x >= entry.right - 2) closeTab(entry.tab);
          else selectTab(entry.index);
        }
      } else if (toolbarPoint) {
        const action = toolbar[itemAt(toolbarLabels, toolbarPoint.x, 1)];
        if (action) shortcut(action[0]);
      } else if (filePoint) {
        model.focus = 'files';
        const row = filePoint.y - 2;
        if (row >= 0 && row < fileRows) openEntry(model.fileTop + row);
      } else if (outlinePoint) {
        model.focus = 'outline';
        const row = outlinePoint.y - 2;
        if (row >= 0 && row < outlineRows) jumpToHeading(model.outlineTop + row);
      } else if (editorPoint && tab) {
        model.focus = 'editor';
        const row = editorPoint.y - 2;
        if (row >= 0 && row < shownRows) {
          placeEditorCursor(tab, editorPoint);
          model.drag = {tab, x: event.x, y: event.y, moved: false};
        }
      } else return;
    }
    refresh();
  });

  const outlineReady = model.outlineSource === outlineSource;
  model.fileTop = scrollOffset(model.fileTop, model.entries.length, fileRows);
  model.outlineTop = scrollOffset(model.outlineTop, outlineReady ? model.outline.length : 0, outlineRows);
  const focusedPane = model.prompt || model.mainPicker || model.logFocused ? null : model.focus;
  const sidebar = h(Box, {width: sideWidth, flexDirection: 'column'},
    (splitSidebar || model.focus !== 'outline') &&
      h(FilesPanel, {panelRef: filesPanel, model, activeFile: active()?.file, width: sideWidth, rows: fileRows,
        split: splitSidebar, focused: focusedPane === 'files'}),
    (splitSidebar || model.focus === 'outline') &&
      h(OutlinePanel, {panelRef: outlinePanel, model, tab: active(), ready: outlineReady, width: sideWidth, rows: outlineRows,
        split: splitSidebar, focused: focusedPane === 'outline'}));
  const editorScreen = model.focus === 'help'
    ? h(HelpPanel, {rows: shownRows})
    : h(Box, {flexDirection: 'row'},
      (wide || sidebarFocused) && sidebar,
      showEditor && h(EditorPanel, {panelRef: editorPanel, tab: currentTab, viewport,
        focused: focusedPane === 'editor', width: editorWidth, rows: shownRows}));
  const picker = model.mainPicker;
  const options = picker ? visibleMainOptions(picker) : [];
  if (picker) picker.offset = scrollOffset(picker.offset, options.length, pickerRows);
  const logLines = model.logVisible ? model.log.split('\n') : [];
  if (model.logVisible) model.logTop = scrollOffset(model.logTop, logLines.length, logFrame.rows);
  const marker = statusMarkers[model.statusTone];
  const statusText = ' ' + (marker ? marker + ' ' : '') + safeText(model.status);
  const helpHint = ' Ctrl+U Help ';

  return h(Box, {flexDirection: 'column', width: columns},
    h(ProjectBar, {toolbarPanel, mainButton, columns, root, main: model.main, building: Boolean(model.build),
      hasPDF: Boolean(model.pdf), showingLog: model.logVisible}),
    h(TabStrip, {panelRef: tabsPanel, tabs, hasTabs: model.tabs.length > 0}),
    h(Box, {position: 'relative', width: columns, height: workHeight, flexShrink: 0, flexDirection: 'column'},
      editorScreen,
      model.logVisible && h(BuildLogPopup, {panelRef: logPanel, closeRef: logClose, frame: logFrame,
        focused: model.logFocused && !picker, lines: logLines.slice(model.logTop)}),
      completionFrame && h(CompletionPopup, {panelRef: completionPanel, frame: completionFrame,
        items: completion.items, index: completion.index}),
      picker && h(MainFilePopup, {panelRef: mainPanel, closeRef: mainClose, frame: mainFrame, picker, options})),
    model.prompt && h(Box, {height: 1},
      h(Text, {color: model.prompt.confirm ? palette.warning : palette.accent, wrap: 'truncate-start'},
        ' ' + model.prompt.label + (model.prompt.confirm ? ' [y/N]' : '  ›  ' + safeText(model.prompt.text) + '▏'))),
    h(Box, {height: 1},
      h(Box, {flexGrow: 1, flexShrink: 1, minWidth: 0},
        h(Text, {color: palette[model.statusTone], wrap: 'truncate-end'}, statusText)),
      columns >= 72 && stringWidth(statusText) + stringWidth(helpHint) <= columns &&
        h(Text, {color: palette.muted}, helpHint)),
    model.url && h(Text, {color: palette.accent, wrap: 'truncate-end'}, ' ' + model.url));
}

function TabStrip({panelRef, tabs, hasTabs}) {
  return h(Box, {ref: panelRef, height: 1, flexShrink: 0, gap: tabGap, paddingLeft: 1},
    tabs.length ? tabs.map(({tab, active, name, labelWidth, width}) =>
      h(Box, {key: tab.file, width, flexShrink: 0, backgroundColor: active ? palette.activeItem : undefined},
        active && h(Text, {color: palette.activeAccent}, '['),
        h(Box, {width: labelWidth, flexShrink: 0},
          h(Text, {color: active ? palette.activeText : palette.muted, bold: active, wrap: 'truncate-end'}, name)),
        tab.dirty && h(Text, {color: active ? palette.activeText : palette.warning}, '*'),
        active && h(Text, {color: palette.activeAccent}, ']'),
        h(Text, {color: active ? palette.activeAccent : palette.muted}, ' ×')))
      : h(Text, {color: palette.muted, wrap: 'truncate-end'}, hasTabs ? 'Tabs' : 'No tabs'));
}

function ProjectBar({toolbarPanel, mainButton, columns, root, main, building, hasPDF, showingLog}) {
  const project = safeText(path.basename(root) || root);
  const source = main ? safeText(path.basename(main)) : 'Main file';
  const controlsWidth = Math.min(columns, toolbarWidth);
  const identityWidth = columns - controlsWidth;
  const sourceWidth = identityWidth >= 8
    ? Math.min(stringWidth(source), Math.max(1, identityWidth - stringWidth(project) - 6, Math.floor(identityWidth / 2) - 3))
    : 0;
  const projectWidth = Math.min(stringWidth(project) + 1, identityWidth - (sourceWidth ? sourceWidth + 5 : 0));

  return h(Box, {width: columns, height: 1, flexShrink: 0},
    projectWidth > 0 && h(Box, {width: projectWidth, flexShrink: 0},
      h(Text, {bold: true, wrap: 'truncate-end'}, ' ' + project)),
    sourceWidth > 0 && h(Text, {color: palette.muted}, ' · '),
    sourceWidth > 0 && h(Box, {ref: mainButton, width: sourceWidth + 2, flexShrink: 0},
      h(Box, {width: sourceWidth, flexShrink: 0},
        h(Text, {color: palette.accent, wrap: 'truncate-start'}, source)),
      h(Text, {color: palette.accent}, ' ▾')),
    h(Box, {flexGrow: 1}),
    h(Box, {ref: toolbarPanel, width: controlsWidth, flexShrink: 0},
      h(Text, {wrap: 'truncate-end'}, ' ',
        ...toolbar.map(([key, label], index) => {
          const primary = key === 'r' && main && !building;
          const openLog = key === 'l' && showingLog;
          const muted = (key === 'r' && (!main || building)) || (key === 'p' && !hasPDF) || (key === 'clean' && building);
          const color = primary ? palette.selectionText : openLog ? palette.accent : muted ? palette.muted : undefined;
          return h(Text, {key}, index > 0 && ' ',
            h(Text, {bold: Boolean(primary || openLog), color,
              backgroundColor: primary ? palette.selection : undefined}, label));
        }))));
}

function PaneHeading({label, detail, focused}) {
  return h(Box, {height: 1, flexShrink: 0},
    h(Text, {color: focused ? palette.accent : undefined, bold: true, wrap: 'truncate-end'},
      ' ' + label, detail && h(Text, {color: palette.muted, bold: false}, detail)));
}

function FilesPanel({panelRef, model, activeFile, width, rows, split, focused}) {
  const offset = model.fileTop;
  const rowsToShow = model.entries.slice(offset, offset + rows);
  const folder = path.relative(model.root, model.folder);
  return h(Box, {ref: panelRef, width, flexDirection: 'column', borderStyle: 'single', borderBottom: !split,
    borderColor: focused ? palette.focusBorder : palette.border},
    h(PaneHeading, {label: 'FILES', detail: folder && ' · ' + safeText(folder), focused}),
    ...rowsToShow.map((entry, index) => {
      const selected = focused && index + offset === model.selected;
      const current = entry.path === activeFile;
      const backgroundColor = selected ? palette.selection : current ? palette.activeItem : undefined;
      const color = selected ? palette.selectionText : current ? palette.activeText : entry.directory ? palette.accent : undefined;
      const markerColor = selected ? palette.selectionText : current ? palette.activeAccent : palette.accent;
      return h(Box, {key: entry.path, height: 1, flexShrink: 0, backgroundColor},
        h(Text, {color, bold: selected || current, wrap: 'truncate-end'},
          selected ? ' › ' : current ? ' • ' : '   ', safeText(entry.name), entry.directory && '/',
          entry.path === model.main && h(Text, {color: markerColor}, ' · M')));
    }),
    ...Array.from({length: rows - rowsToShow.length}, (_, index) => h(Text, {key: 'blank-' + index}, ' ')));
}

function OutlinePanel({panelRef, model, tab, ready, width, rows, split, focused}) {
  const headings = ready ? model.outline : [];
  const offset = model.outlineTop;
  const entries = headings.slice(offset, offset + rows);
  let current = -1;
  if (tab) {
    const {row} = tab.position;
    for (let index = 0; index < headings.length; index++) {
      const heading = headings[index];
      if (heading.file === tab.file && heading.line <= row &&
          (current < 0 || heading.line > headings[current].line)) current = index;
    }
  }
  const rendered = entries.map((heading, index) => {
    const highlighted = offset + index === current;
    const selected = focused && offset + index === model.outlineSelected;
    const indent = ' '.repeat(Math.min(8, 2 * (heading.level - model.outlineDepth)));
    const backgroundColor = selected ? palette.selection : highlighted ? palette.activeItem : undefined;
    return h(Box, {key: offset + index, height: 1, flexShrink: 0, backgroundColor},
      h(Text, {color: selected ? palette.selectionText : highlighted ? palette.activeText : undefined,
        bold: highlighted || selected, wrap: 'truncate-end'},
      (selected ? ' › ' : highlighted ? ' • ' : '   ') + indent + safeText(heading.title)));
  });
  if (!rendered.length) rendered.push(h(Text, {key: 'empty', color: palette.muted, wrap: 'truncate-end'},
    ready ? ' No section headings' : ' Loading…'));
  return h(Box, {ref: panelRef, width, flexDirection: 'column', borderStyle: split ? outlineDividerBorder : 'single',
    borderColor: focused ? palette.focusBorder : palette.border},
    h(PaneHeading, {label: 'OUTLINE', detail: '  Ctrl+D', focused}),
    ...rendered,
    ...Array.from({length: rows - rendered.length}, (_, index) => h(Text, {key: 'blank-' + index}, ' ')));
}

function EditorPanel({panelRef, tab, viewport, focused, width, rows}) {
  let visible = [];
  if (tab) {
    const {wrap, cursorRow, page, column} = viewport;
    const selection = tab.selection;
    const gutter = gutterWidth(tab);
    const space = sourceColumns(tab, width);
    const tex = isTeX(tab.file);
    visible = page.map(segment => {
      const {text, start} = tab.lines[segment.row];
      const current = compareRows(segment, cursorRow) === 0;
      const backgroundColor = current ? palette.activeLine : undefined;
      const colors = current ? activeSyntaxColors : syntaxColors;
      const foreground = current ? palette.activeText : undefined;
      const caret = current && focused ? column : -1;
      const span = segment.right - segment.left;
      const selected = selection ? {start: selection.start - start, end: selection.end - start} : undefined;
      const selectsNewline = Boolean(selected && selected.start <= text.length && selected.end > text.length);
      const visibleWidth = Math.min(space, span + Number(caret === text.length || selectsNewline));
      const cells = lineCells(text, caret, segment.left, visibleWidth, tex ? latexTokens(text) : undefined, segment, selected);
      if (caret >= 0 && span > space && wrap.cellAt(segment, caret) >= space && cells.length) {
        cells.at(-1).cursor = true;
      }
      const runs = [];
      for (const part of cells) {
        const last = runs.at(-1);
        if (last && last.cursor === part.cursor && last.color === part.color && last.selected === part.selected) last.text += part.text;
        else runs.push({...part});
      }
      const used = runs.reduce((columns, part) => columns + stringWidth(part.text), 0);
      const label = segment.part === 0 ? String(segment.row + 1) : '↳';
      return h(Text, {key: segment.row + ':' + segment.part, wrap: 'truncate-end'},
        h(Text, {color: current ? palette.activeAccent : palette.muted, backgroundColor},
          label.padStart(gutter - 3) + ' │ '),
        ...runs.map((part, key) => h(Text, {key, inverse: part.cursor,
          color: part.cursor ? foreground : part.selected ? palette.selectionText : colors[part.color] ?? foreground,
          backgroundColor: !part.cursor && part.selected ? palette.selection : backgroundColor}, part.text)),
        current && h(Text, {backgroundColor}, ' '.repeat(Math.max(0, space - used))));
    });
  }
  if (!tab) visible = [h(Text, {key: 'empty', color: palette.muted, wrap: 'truncate-end'},
    ' Open a text file or press Ctrl+N.')];
  const detail = tab && ' · ' + safeText(path.basename(tab.file)) + ' · ' +
    (tab.position.row + 1) + ':' + (tab.position.column + 1);
  return h(Box, {ref: panelRef, width, flexDirection: 'column', borderStyle: 'single',
    borderColor: focused ? palette.focusBorder : palette.border},
    h(PaneHeading, {label: 'SOURCE', detail, focused}),
    ...visible,
    ...Array.from({length: Math.max(0, rows - visible.length)}, (_, index) => h(Text, {key: 'blank-' + index}, ' ')));
}

function HelpPanel({rows}) {
  const visible = help.slice(0, rows);
  return h(Box, {flexDirection: 'column', borderStyle: 'single', borderColor: palette.focusBorder},
    h(PaneHeading, {label: 'KEYBOARD', focused: true}),
    ...visible.map((line, index) => h(Text, {key: index, wrap: 'truncate-end'}, ' ' + line)),
    ...Array.from({length: rows - visible.length}, (_, index) => h(Text, {key: 'blank-' + index}, ' ')));
}

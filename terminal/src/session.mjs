import {createHash, randomUUID} from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const version = 1;

function sessionDirectory() {
  const override = process.env.PAGEQUOIN_STATE_DIR;
  if (override) return path.resolve(override);

  const home = os.homedir();
  if (process.platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'PageQuoin', 'sessions');
  if (process.platform === 'win32') {
    const local = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
    return path.join(local, 'PageQuoin Terminal', 'sessions');
  }
  const xdg = process.env.XDG_STATE_HOME;
  const local = xdg && path.isAbsolute(xdg) ? xdg : path.join(home, '.local', 'state');
  return path.join(local, 'pagequoin-terminal', 'sessions');
}

function legacyDirectory() {
  if (process.platform !== 'darwin' || process.env.PAGEQUOIN_STATE_DIR) return null;
  return path.join(os.homedir(), 'Library', 'Application Support', 'PageQuoin Terminal', 'sessions');
}

function recordName(root, suffix = '.json') {
  return createHash('sha256').update(root).digest('hex') + suffix;
}

function validRoot(root) {
  return typeof root === 'string' && path.isAbsolute(root) && !root.includes('\0');
}

function isRelativeFile(value) {
  return typeof value === 'string' && !value.includes('\0') &&
    (process.platform !== 'win32' || !/[\\:]/.test(value)) &&
    value.split('/').every(part => part !== '' && part !== '.' && part !== '..');
}

function isPosition(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function isObject(value) {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value));
}

function readRecord(value) {
  if (value?.version !== version || !validRoot(value.root) || !isPosition(value.updatedAt) || !Array.isArray(value.tabs) ||
      ![value.main, value.active, value.pdf].every(file => file === null || isRelativeFile(file)) ||
      !value.tabs.every(tab => tab && isRelativeFile(tab.file) &&
        [tab.cursor, tab.top, tab.left].every(isPosition) &&
        (tab.wrapStart === undefined || isPosition(tab.wrapStart)))) {
    return null;
  }
  const {root, main, active, pdf, updatedAt} = value;
  const tabs = value.tabs.map(({file, cursor, top, left, wrapStart, desktopOnly, desktopPosition}) => ({
    file, cursor, top, left,
    ...(wrapStart === undefined ? {} : {wrapStart}),
    ...(desktopOnly === true ? {desktopOnly} : {}),
    ...(isObject(desktopPosition) ? {desktopPosition} : {}),
  }));
  return {
    root, main, active, tabs, pdf, updatedAt,
    ...(isObject(value.desktopWorkspace) ? {desktopWorkspace: value.desktopWorkspace} : {}),
  };
}

async function readJSON(file) {
  try {
    if (!(await fs.lstat(file)).isFile()) return null;
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch {
    return null;
  }
}

export async function readSession(root) {
  const removedAt = await readSessionRemoval(root);
  for (const directory of [sessionDirectory(), legacyDirectory()].filter(Boolean)) {
    const state = readRecord(await readJSON(path.join(directory, recordName(root))));
    if (state?.root === root && state.updatedAt > (removedAt ?? -1)) return state;
  }
  return null;
}

export async function readSessionRemoval(root) {
  const value = await readJSON(path.join(sessionDirectory(), recordName(root, '.removed.json')));
  if (value?.version !== version || value.root !== root ||
      !isPosition(value.removedAt) || value.removedAt === Number.MAX_SAFE_INTEGER) return null;
  return value.removedAt;
}

export async function removeSession(root) {
  if (!validRoot(root)) throw new Error('Choose a valid recent project.');
  const previous = await readSessionRemoval(root);
  const state = await readSession(root);
  const removedAt = Math.max(Date.now(), (previous ?? -1) + 1, state?.updatedAt ?? 0);
  await writeJSON(recordName(root, '.removed.json'), {version, root, removedAt});
}

async function sessionsIn(directory) {
  let entries;
  try {
    entries = await fs.readdir(directory, {withFileTypes: true});
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }

  const sessions = [];
  for (const entry of entries) {
    if (!entry.isFile() || !/^[0-9a-f]{64}\.json$/.test(entry.name)) continue;
    const state = readRecord(await readJSON(path.join(directory, entry.name)));
    if (state && recordName(state.root) === entry.name) sessions.push(state);
  }
  return sessions;
}

export async function listSessions() {
  const current = await sessionsIn(sessionDirectory());
  const legacy = legacyDirectory();
  const candidates = legacy ? current.concat(await sessionsIn(legacy).catch(() => [])) : current;
  const removals = new Map(await Promise.all(
    [...new Set(candidates.map(({root}) => root))].map(async root => [root, await readSessionRemoval(root)])));
  const merged = new Map();
  for (const state of candidates) {
    if (!merged.has(state.root) && state.updatedAt > (removals.get(state.root) ?? -1)) merged.set(state.root, state);
  }
  return [...merged.values()].sort((a, b) => b.updatedAt - a.updatedAt || a.root.localeCompare(b.root));
}

export async function readMainSelection(root) {
  const value = await readJSON(path.join(sessionDirectory(), recordName(root, '.main.json')));
  if (value?.version !== version || value.root !== root ||
      !(value.selectedMain === null || isRelativeFile(value.selectedMain))) return undefined;
  return value.selectedMain;
}

export async function saveMainSelection(root, selectedMain) {
  if (!path.isAbsolute(root) || !(selectedMain === null || isRelativeFile(selectedMain))) {
    throw new Error('Could not save an invalid main file.');
  }
  await writeJSON(recordName(root, '.main.json'), {version, root, selectedMain});
}

export async function saveSession({root, main, active, tabs, pdf}, {removedAtOnOpen} = {}) {
  const now = Date.now();
  if (!validRoot(root)) throw new Error('Could not save an invalid session.');
  const removedAt = await readSessionRemoval(root);
  // A project that was open before it was removed must stay out of Recent Projects.
  if (removedAtOnOpen !== undefined && removedAtOnOpen !== removedAt) return;
  const updatedAt = Math.max(now, (removedAt ?? -1) + 1);
  const state = readRecord({version, root, main, active, tabs, pdf, updatedAt});
  if (!state) throw new Error('Could not save an invalid session.');
  const previous = await readSession(root);
  if (previous?.desktopWorkspace) state.desktopWorkspace = previous.desktopWorkspace;
  if (previous) {
    const current = new Map(state.tabs.map(tab => [tab.file, tab]));
    previous.tabs.forEach((existing, index) => {
      const tab = current.get(existing.file);
      if (!tab && existing.desktopOnly) state.tabs.splice(Math.min(index, state.tabs.length), 0, existing);
      else if (tab && tab.cursor === existing.cursor && existing.desktopPosition) {
        tab.desktopPosition = existing.desktopPosition;
      }
    });
  }
  await writeJSON(recordName(root), {version, ...state});
}

async function writeJSON(name, value) {
  const directory = sessionDirectory();
  await fs.mkdir(directory, {recursive: true, mode: 0o700});
  const destination = path.join(directory, name);
  const temporary = path.join(directory, '.' + randomUUID() + '.tmp');
  try {
    await fs.writeFile(temporary, JSON.stringify(value) + '\n', {flag: 'wx', mode: 0o600});
    await fs.rename(temporary, destination);
  } finally {
    await fs.rm(temporary, {force: true}).catch(() => {});
  }
}

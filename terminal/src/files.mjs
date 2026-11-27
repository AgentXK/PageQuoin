import * as fs from 'node:fs/promises';
import path from 'node:path';
import {randomUUID} from 'node:crypto';

const maxFileMiB = 32;
const maxFileSize = maxFileMiB * 1024 * 1024;
export const isTeX = file => /\.(tex|ltx)$/i.test(file);
const decoder = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});

function inside(root, file) {
  const relative = path.relative(root, file);
  return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

export async function projectPath(root, input, {create = false} = {}) {
  const candidate = path.resolve(root, input);
  if (!inside(root, candidate)) throw new Error('Choose a path inside this project.');
  const file = create
    ? path.join(await fs.realpath(path.dirname(candidate)), path.basename(candidate))
    : await fs.realpath(candidate);
  if (!inside(root, file)) throw new Error('This path points outside the project.');
  return file;
}

async function readTextFile(file) {
  const handle = await fs.open(file, 'r');
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new Error('Choose a regular text file.');
    if (info.size > maxFileSize) {
      const size = (info.size / (1024 * 1024)).toFixed(1);
      throw new Error(`${path.basename(file)} is ${size} MiB. The text editing limit is ${maxFileMiB} MiB.`);
    }
    const data = Buffer.alloc(info.size + 1);
    let length = 0;
    while (length < data.length) {
      const {bytesRead} = await handle.read(data, length, data.length - length, length);
      if (bytesRead === 0) break;
      length += bytesRead;
    }
    const after = await handle.stat();
    if (length !== info.size || after.size !== info.size || after.mtimeMs !== info.mtimeMs) {
      throw new Error('The file changed while it was being read. Try again.');
    }
    return {bytes: data.subarray(0, length), mode: info.mode & 0o777};
  } finally {
    await handle.close();
  }
}

export function decodeText(bytes) {
  let encoding = 'utf8';
  let prefix = Buffer.alloc(0);
  if (bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]))) prefix = bytes.subarray(0, 3);
  else if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    encoding = 'utf16le';
    prefix = bytes.subarray(0, 2);
  } else if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    encoding = 'utf16be';
    prefix = bytes.subarray(0, 2);
  }

  let text;
  try {
    const body = bytes.subarray(prefix.length);
    text = encoding === 'utf8'
      ? decoder.decode(body)
      : new TextDecoder(encoding === 'utf16le' ? 'utf-16le' : 'utf-16be', {fatal: true, ignoreBOM: true}).decode(body);
  } catch {
    throw new Error('PageQuoin Terminal opens UTF-8 and BOM-marked UTF-16 text files.');
  }
  if (text.includes('\0')) throw new Error('This file contains binary data.');
  const eol = text.match(/\r\n|\r|\n/)?.[0] ?? '\n';
  const hasCR = text.includes('\r');
  const mixedEndings = eol === '\n' ? hasCR : eol === '\r' ? text.includes('\n') : /\r(?!\n)|(?<!\r)\n/.test(text);
  return {text: hasCR ? text.replace(/\r\n?/g, '\n') : text, encoding, prefix, eol, mixedEndings};
}

export function encodeText(text, format) {
  const normalized = format.eol === '\n' ? text : text.replaceAll('\n', format.eol);
  const body = Buffer.from(normalized, format.encoding === 'utf8' ? 'utf8' : 'utf16le');
  if (format.encoding === 'utf16be') body.swap16();
  return Buffer.concat([format.prefix, body]);
}

export async function readDocument(file) {
  const {bytes, mode} = await readTextFile(file);
  return {bytes, mode, ...decodeText(bytes)};
}

export async function saveDocument(root, file, text, snapshot) {
  if (snapshot.mixedEndings) throw new Error('Mixed line endings. Save a copy in a single line-ending format first.');
  const data = encodeText(text, snapshot);
  if (data.length > maxFileSize) throw new Error(`The file would exceed the ${maxFileMiB} MiB editing limit.`);
  const confirmUnchanged = async () => {
    if (await projectPath(root, file) !== file || !(await readTextFile(file)).bytes.equals(snapshot.bytes)) {
      throw new Error('File changed on disk. Keep this tab open and save a copy with Ctrl+E.');
    }
  };
  await confirmUnchanged();
  const temporary = path.join(path.dirname(file), '.pagequoin-save-' + randomUUID());
  try {
    await fs.writeFile(temporary, data, {flag: 'wx', mode: snapshot.mode});
    if (process.platform !== 'win32') await fs.chmod(temporary, snapshot.mode);
    await confirmUnchanged();
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, {force: true}).catch(() => {});
  }
  return {...snapshot, bytes: data, text};
}

export async function newDocument(root, input, content = '') {
  if (!input.trim()) throw new Error('Enter a file name.');
  const file = await projectPath(root, input, {create: true});
  await fs.writeFile(file, content, {flag: 'wx'});
  return file;
}

async function visibleEntries(directory) {
  return (await fs.readdir(directory, {withFileTypes: true}))
    .filter(entry => !entry.name.startsWith('.') && (entry.isDirectory() || entry.isFile()))
    .map(entry => ({name: entry.name, directory: entry.isDirectory(), path: path.join(directory, entry.name)}));
}

export async function projectEntries(root, folder) {
  const directory = await projectPath(root, folder);
  const entries = await visibleEntries(directory);
  entries.sort((a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name, undefined, {numeric: true}));
  if (directory !== root) entries.unshift({name: '..', directory: true, path: path.dirname(directory)});
  return entries;
}

export async function listTeXFiles(root) {
  const project = await fs.realpath(root);
  const folders = [project];
  const files = [];
  while (folders.length) {
    const folder = folders.pop();
    let entries;
    try {
      if (folder !== project && await fs.realpath(folder) !== folder) continue;
      entries = await visibleEntries(folder);
    } catch (error) {
      if (folder === project || !['ENOENT', 'ENOTDIR', 'EACCES', 'EPERM', 'ELOOP'].includes(error.code)) throw error;
      continue;
    }
    for (const entry of entries) {
      if (entry.directory) {
        if (entry.name !== 'node_modules') folders.push(entry.path);
      } else if (isTeX(entry.name)) {
        files.push({
          path: entry.path,
          relative: path.relative(project, entry.path).split(path.sep).join('/'),
          nested: folder === project ? 0 : 1,
        });
      }
    }
  }
  const order = new Intl.Collator(undefined, {numeric: true});
  files.sort((a, b) => a.nested - b.nested || order.compare(a.relative, b.relative));
  return files.map(file => file.path);
}

export async function findMain(root, initialFile) {
  const candidates = (await projectEntries(root, root)).filter(entry => !entry.directory && isTeX(entry.path));
  const main = candidates.find(entry => entry.name.toLowerCase() === 'main.tex');
  if (main) return main.path;
  for (const file of new Set([initialFile, ...candidates.map(entry => entry.path)].filter(file => file && isTeX(file)))) {
    const document = await readDocument(file).catch(() => null);
    if (document && /^[^\S\n]*\\documentclass\b/m.test(document.text)) return file;
  }
  return initialFile && isTeX(initialFile) ? initialFile : null;
}

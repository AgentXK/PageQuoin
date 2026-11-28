import {spawn} from 'node:child_process';
import {randomBytes, randomUUID} from 'node:crypto';
import {constants} from 'node:fs';
import * as fs from 'node:fs/promises';
import {createServer} from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {pipeline} from 'node:stream/promises';
import {isTeX, projectPath} from './files.mjs';

export const logLimit = 64 * 1024;
const buildFolder = '.pagequoin-build';
const markerFile = '.pagequoin-owned';
const marker = Buffer.from('PageQuoin Build Artifacts v1\n');
const desktopTargetName = /^[\p{L}\p{M}\p{N}_-]*-[0-9a-f]{16}$/u;
const desktopBuildLog = 'tectonic-output.log';
const pdfHeader = Buffer.from('%PDF-');

async function lstatIfPresent(file) {
  try { return await fs.lstat(file); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function ownsBuildDirectory(directory) {
  if (!(await lstatIfPresent(directory))?.isDirectory()) return false;
  const file = path.join(directory, markerFile);
  const info = await lstatIfPresent(file);
  return info?.isFile() && info.size === marker.length && (await fs.readFile(file)).equals(marker);
}

function unmanagedBuildDirectory(directory) {
  return new Error('PageQuoin does not own the folder “' + directory + '”.');
}

async function entriesIfPresent(directory) {
  try { return await fs.readdir(directory, {withFileTypes: true}); }
  catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

async function sameDirectory(directory, original) {
  const current = await lstatIfPresent(directory);
  return current?.isDirectory() && current.dev === original.dev && current.ino === original.ino;
}

async function unlinkRegularFile(file) {
  if (!(await lstatIfPresent(file))?.isFile()) return 0;
  try {
    await fs.unlink(file);
    return 1;
  } catch (error) {
    if (error.code === 'ENOENT') return 0;
    throw error;
  }
}

async function cleanBuildTarget(directory, isCurrent, identifyingLog) {
  if (!(await isCurrent())) return 0;
  let removed = 0;
  for (const entry of await entriesIfPresent(directory)) {
    // The desktop publisher can swap a new completed build into this path.
    if (!(await isCurrent())) return removed;
    if (entry.name === identifyingLog) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const info = await lstatIfPresent(file);
      if (info?.isDirectory()) {
        removed += await cleanBuildTarget(file, async () => await isCurrent() && await sameDirectory(file, info));
      }
    } else if (entry.isFile() && path.extname(entry.name).toLowerCase() !== '.pdf') {
      removed += await unlinkRegularFile(file);
    }
  }
  // Remove the identifying log last so a partial cleanup can be retried.
  if (identifyingLog && await isCurrent()) {
    removed += await unlinkRegularFile(path.join(directory, identifyingLog));
  }
  return removed;
}

export async function cleanBuildIntermediates(root) {
  const storage = path.join(root, buildFolder);
  const storageInfo = await lstatIfPresent(storage);
  if (!storageInfo) return 0;
  const owned = await ownsBuildDirectory(storage).catch(error => {
    if (error.code === 'ENOENT') return false;
    throw error;
  });
  if (!owned) {
    if (!(await lstatIfPresent(storage))) return 0;
    throw unmanagedBuildDirectory(storage);
  }

  let removed = 0;
  for (const entry of await entriesIfPresent(storage)) {
    if (!entry.isDirectory() || !desktopTargetName.test(entry.name)) continue;
    if (!(await sameDirectory(storage, storageInfo))) break;
    const target = path.join(storage, entry.name);
    const targetInfo = await lstatIfPresent(target);
    if (!targetInfo?.isDirectory() || !(await lstatIfPresent(path.join(target, desktopBuildLog)))?.isFile()) continue;
    const isCurrent = async () => await sameDirectory(storage, storageInfo) && await sameDirectory(target, targetInfo);
    removed += await cleanBuildTarget(target, isCurrent, desktopBuildLog);
  }
  return removed;
}

function siblingPDF(source) {
  const {dir, name} = path.parse(source);
  return path.join(dir, name + '.pdf');
}

async function openPDF(file) {
  const expected = await lstatIfPresent(file);
  if (!expected?.isFile()) return null;
  const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0);
  const handle = await fs.open(file, flags);
  let valid = false;
  try {
    const info = await handle.stat();
    if (!info.isFile()) return null;
    if (!constants.O_NOFOLLOW) {
      const current = await lstatIfPresent(file);
      if (!current?.isFile() || current.dev !== info.dev || current.ino !== info.ino) return null;
    }
    const header = Buffer.alloc(pdfHeader.length);
    const {bytesRead} = await handle.read(header, 0, header.length, 0);
    valid = bytesRead === header.length && header.equals(pdfHeader);
    return valid ? {handle, size: info.size} : null;
  } finally {
    if (!valid) await handle.close();
  }
}

async function hasPDFHeader(file) {
  const pdf = await openPDF(file);
  if (!pdf) return false;
  await pdf.handle.close();
  return true;
}

export async function readSharedPDF(root, main) {
  if (!main) return null;
  try {
    const source = await projectPath(root, main);
    if (!isTeX(source) || !(await lstatIfPresent(source))?.isFile()) return null;
    const pdf = siblingPDF(source);
    return await hasPDFHeader(pdf) ? pdf : null;
  } catch {
    // The project has no readable output for its main document.
    return null;
  }
}

function runEngine(engine, args, cwd, signal, onOutput) {
  return new Promise((resolve, reject) => {
    const child = spawn(engine, args, {cwd, signal, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']});
    let failure;
    child.once('error', error => { failure = error; });
    for (const stream of [child.stdout, child.stderr]) {
      stream.setEncoding('utf8');
      stream.on('data', onOutput);
    }
    child.once('close', (code, exitSignal) => {
      if (signal?.aborted) reject(new Error('Build stopped.'));
      else if (failure?.code === 'ENOENT') reject(new Error('Tectonic was not found. Add it to PATH or set TECTONIC_PATH.'));
      else if (failure) reject(failure);
      else if (code !== 0) reject(new Error('Tectonic failed (' + (exitSignal ?? code) + '). Press Ctrl+L for the log.'));
      else resolve();
    });
  });
}

async function requireExportDestination(root, file, sourceDirectoryInfo) {
  if (await projectPath(root, file, {create: true}) !== file ||
      !(await sameDirectory(path.dirname(file), sourceDirectoryInfo))) {
    throw new Error('The main document folder changed during the build.');
  }
  const previous = await lstatIfPresent(file);
  if (previous && !previous.isFile()) {
    throw new Error('PDF output cannot replace a non-regular file.');
  }
}

export async function compilePDF(root, main, {
  engine = process.env.TECTONIC_PATH?.trim() || 'tectonic', signal, onOutput = () => {},
} = {}) {
  if (signal?.aborted) throw new Error('Build stopped.');
  const source = await projectPath(root, main);
  if (!isTeX(source) || !(await lstatIfPresent(source))?.isFile()) {
    throw new Error('Choose a regular .tex or .ltx main document.');
  }
  const sourceDirectory = path.dirname(source);
  const sourceDirectoryInfo = await fs.lstat(sourceDirectory);
  const exported = siblingPDF(source);
  const staging = await fs.mkdtemp(path.join(os.tmpdir(), 'pagequoin-tectonic-'));
  let stagedPDF;
  try {
    if (signal?.aborted) throw new Error('Build stopped.');
    await runEngine(engine, ['--untrusted', '--color', 'never', '--outdir', staging, source],
      sourceDirectory, signal, onOutput);
    const generated = path.join(staging, path.basename(exported));
    if (!(await hasPDFHeader(generated))) throw new Error('Tectonic did not produce a PDF.');
    if (signal?.aborted) throw new Error('Build stopped.');

    await requireExportDestination(root, exported, sourceDirectoryInfo);
    if (signal?.aborted) throw new Error('Build stopped.');
    try {
      await fs.rename(generated, exported);
      return exported;
    } catch (error) {
      if (error.code !== 'EXDEV') throw error;
    }

    // On a different volume, stage the finished PDF beside its destination for atomic replacement.
    const temporaryPDF = path.join(sourceDirectory, '.pagequoin-pdf-' + randomUUID());
    await fs.copyFile(generated, temporaryPDF, constants.COPYFILE_EXCL);
    stagedPDF = temporaryPDF;
    await requireExportDestination(root, exported, sourceDirectoryInfo);
    if (signal?.aborted) throw new Error('Build stopped.');
    await fs.rename(stagedPDF, exported);
    stagedPDF = undefined;
    return exported;
  } finally {
    if (stagedPDF && await sameDirectory(sourceDirectory, sourceDirectoryInfo).catch(() => false)) {
      await fs.unlink(stagedPDF).catch(() => {});
    }
    await fs.rm(staging, {recursive: true, force: true}).catch(() => {});
  }
}

export function createPreview() {
  let selected;
  let listening;
  const host = '127.0.0.1';
  const server = createServer(async (request, response) => {
    const preview = selected;
    if (!preview || request.url !== preview.endpoint || !['GET', 'HEAD'].includes(request.method) ||
        request.headers.host !== host + ':' + server.address()?.port) {
      response.writeHead(404).end();
      return;
    }
    let handle;
    try {
      const pdf = await openPDF(preview.file);
      if (!pdf) {
        response.writeHead(404).end();
        return;
      }
      handle = pdf.handle;
      response.writeHead(200, {
        'Content-Type': 'application/pdf',
        'Content-Disposition': "inline; filename*=UTF-8''" + preview.name,
        'Content-Length': pdf.size,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Cross-Origin-Resource-Policy': 'same-origin',
      });
      if (request.method === 'HEAD') response.end();
      else await pipeline(handle.createReadStream({start: 0}), response);
    } catch {
      if (!response.headersSent) response.writeHead(404).end();
      else response.destroy();
    } finally {
      await handle?.close().catch(() => {});
    }
  });

  return {
    async url(pdf) {
      if (selected?.file !== pdf) {
        const name = encodeURIComponent(path.basename(pdf)).replace(/[!'()*]/g,
          character => '%' + character.charCodeAt(0).toString(16).toUpperCase());
        selected = {file: pdf, name, endpoint: '/' + randomBytes(24).toString('hex') + '/' + name};
      }
      const {endpoint} = selected;
      listening ??= new Promise((resolve, reject) => {
        const onError = error => {
          listening = undefined;
          reject(error);
        };
        server.once('error', onError);
        server.listen(0, host, () => {
          server.off('error', onError);
          resolve();
        });
      });
      await listening;
      return 'http://' + host + ':' + server.address().port + endpoint;
    },
    async close() {
      await listening?.catch(() => {});
      if (!server.listening) return;
      const closed = new Promise(resolve => server.close(resolve));
      server.closeAllConnections();
      await closed;
      listening = undefined;
    },
  };
}

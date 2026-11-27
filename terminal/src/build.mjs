import {spawn} from 'node:child_process';
import {randomBytes, createHash} from 'node:crypto';
import * as fs from 'node:fs/promises';
import {createServer} from 'node:http';
import path from 'node:path';
import {pipeline} from 'node:stream/promises';
import {setTimeout as pause} from 'node:timers/promises';
import {isTeX, projectPath} from './files.mjs';

export const logLimit = 64 * 1024;
const buildFolder = '.pagequoin-build';
const previewsFolder = 'previews';
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

async function requireDirectory(directory) {
  if (!(await fs.lstat(directory)).isDirectory()) {
    throw new Error('Build output needs a regular directory inside the project.');
  }
}

async function createDirectory(directory) {
  try {
    await fs.mkdir(directory, {mode: 0o700});
    return true;
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    return false;
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

async function prepareBuildDirectory(root) {
  const directory = path.join(root, buildFolder);
  if (await createDirectory(directory)) {
    try {
      await fs.writeFile(path.join(directory, markerFile), marker, {flag: 'wx', mode: 0o600});
    } catch (error) {
      await fs.rmdir(directory).catch(() => {});
      throw error;
    }
  }
  // Another app instance may be between creating the root and writing its marker.
  for (let attempt = 0; attempt < 4; attempt++) {
    if (await ownsBuildDirectory(directory)) return directory;
    if (attempt < 3) await pause(25);
  }
  throw unmanagedBuildDirectory(directory);
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

function pdfName(root, source) {
  const relative = path.relative(root, source).split(path.sep).join('/');
  return createHash('sha256').update(relative).digest('hex').slice(0, 16) + '.pdf';
}

async function hasPDFHeader(file) {
  if (!(await lstatIfPresent(file))?.isFile()) return false;
  const handle = await fs.open(file, 'r');
  try {
    const header = Buffer.alloc(pdfHeader.length);
    const {bytesRead} = await handle.read(header, 0, header.length, 0);
    return bytesRead === header.length && header.equals(pdfHeader);
  } finally {
    await handle.close();
  }
}

export async function readSharedPDF(root, main) {
  if (!main) return null;
  try {
    const source = await projectPath(root, main);
    const storage = path.join(root, buildFolder);
    if (!(await ownsBuildDirectory(storage))) return null;
    const previews = path.join(storage, previewsFolder);
    if (!(await lstatIfPresent(previews))?.isDirectory()) return null;
    const pdf = path.join(previews, pdfName(root, source));
    if (!(await hasPDFHeader(pdf))) return null;
    return await projectPath(root, pdf);
  } catch {
    // An absent or invalid build cache is equivalent to no previous PDF.
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
  engine = process.env.TECTONIC_PATH?.trim() || 'tectonic', signal, onOutput = () => {}, onExport,
} = {}) {
  if (signal?.aborted) throw new Error('Build stopped.');
  const source = await projectPath(root, main);
  const sourceDirectory = path.dirname(source);
  const sourceDirectoryInfo = await fs.lstat(sourceDirectory);
  const storage = await prepareBuildDirectory(root);
  const previews = path.join(storage, previewsFolder);
  await createDirectory(previews);
  await requireDirectory(previews);
  const staging = await fs.mkdtemp(path.join(storage, '.terminal-run-'));
  const basename = path.parse(source).name;
  const published = path.join(previews, pdfName(root, source));
  const exported = path.join(sourceDirectory, basename + '.pdf');
  let exportStaging;
  try {
    if (signal?.aborted) throw new Error('Build stopped.');
    await runEngine(engine, ['--untrusted', '--color', 'never', '--outdir', staging, source],
      sourceDirectory, signal, onOutput);
    const generated = path.join(staging, basename + '.pdf');
    if (!(await hasPDFHeader(generated))) throw new Error('Tectonic did not produce a PDF.');
    if (signal?.aborted) throw new Error('Build stopped.');

    let exportError = null;
    try {
      if (!isTeX(source)) throw new Error('Choose a .tex or .ltx main document to save a PDF beside it.');
      await requireExportDestination(root, exported, sourceDirectoryInfo);
      exportStaging = await fs.mkdtemp(path.join(sourceDirectory, '.pagequoin-pdf-'));
      await fs.copyFile(generated, path.join(exportStaging, 'output.pdf'));
    } catch (error) {
      exportError = error;
    }

    if (!(await ownsBuildDirectory(storage))) throw new Error('The build directory was removed or changed.');
    await requireDirectory(previews);
    const previous = await lstatIfPresent(published);
    if (previous && !previous.isFile()) throw new Error('Build output cannot replace a non-regular file.');
    if (signal?.aborted) throw new Error('Build stopped.');
    await fs.rename(generated, published);

    if (!exportError) {
      try {
        await requireExportDestination(root, exported, sourceDirectoryInfo);
        if (signal?.aborted) throw new Error('Build stopped before saving the project PDF.');
        await fs.rename(path.join(exportStaging, 'output.pdf'), exported);
      } catch (error) {
        exportError = error;
      }
    }
    onExport?.({file: exported, error: exportError});
    return published;
  } finally {
    if (exportStaging && await sameDirectory(sourceDirectory, sourceDirectoryInfo).catch(() => false)) {
      await fs.rm(exportStaging, {recursive: true, force: true}).catch(() => {});
    }
    await fs.rm(staging, {recursive: true, force: true}).catch(() => {});
  }
}

export function createPreview() {
  const endpoint = '/' + randomBytes(24).toString('hex') + '/preview.pdf';
  let file;
  let listening;
  const host = '127.0.0.1';
  const server = createServer(async (request, response) => {
    if (request.url !== endpoint || !file || !['GET', 'HEAD'].includes(request.method) ||
        request.headers.host !== host + ':' + server.address()?.port) {
      response.writeHead(404).end();
      return;
    }
    let handle;
    try {
      handle = await fs.open(file, 'r');
      const info = await handle.stat();
      response.writeHead(200, {
        'Content-Type': 'application/pdf',
        'Content-Disposition': 'inline',
        'Content-Length': info.size,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Cross-Origin-Resource-Policy': 'same-origin',
      });
      if (request.method === 'HEAD') response.end();
      else await pipeline(handle.createReadStream(), response);
    } catch {
      if (!response.headersSent) response.writeHead(404).end();
      else response.destroy();
    } finally {
      await handle?.close().catch(() => {});
    }
  });

  return {
    async url(pdf) {
      file = pdf;
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

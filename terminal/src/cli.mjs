#!/usr/bin/env node
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {parseArgs} from 'node:util';
import React from 'react';
import {render} from 'ink';
import {App} from './app.mjs';
import {readSharedPDF} from './build.mjs';
import {findMain, isTeX, projectEntries, projectPath} from './files.mjs';
import {MouseTracking} from './mouse.mjs';
import {ResumePicker} from './resume-picker.mjs';
import {listSessions, readMainSelection, readSession, readSessionRemoval, removeSession, saveMainSelection} from './session.mjs';

const help = [
  'PageQuoin Terminal — local LaTeX editor',
  '',
  'Usage: pq [project-folder | source-file] [--main PATH] [--no-mouse]',
  '       pq resume [--last] [--no-mouse]',
  '       pq --help',
  '',
  'The full command name pagequoin also works.',
  'With no path, open the current working directory and restore its workspace.',
  'Use resume to pick a recent project, or resume --last to reopen the latest.',
  'In the resume picker, press Ctrl+D or Delete, or click × to remove a recent project.',
  'Use --no-mouse to leave mouse gestures to your terminal.',
  'Autosave waits 1000 ms by default. Use --autosave-delay MS (1000 or more) or --no-autosave.',
  '',
  'Run in an interactive terminal with Node.js 22+ and Tectonic on PATH.',
  'Set TECTONIC_PATH to use a specific Tectonic executable.',
].join('\n');

async function loadProject(target, {main, session, autosaveDelay} = {}) {
  const resolved = await fs.realpath(path.resolve(target));
  const info = await fs.stat(resolved);
  if (!info.isDirectory() && !info.isFile()) throw new Error('Choose a project directory or a regular source file.');
  const root = info.isDirectory() ? resolved : path.dirname(resolved);
  if (session && (!info.isDirectory() || root !== session.root)) throw new Error('This project has moved.');
  const initial = info.isFile() ? resolved : null;
  const removedAtOnOpen = await readSessionRemoval(root);
  const saved = await readSession(root);
  if (session && !saved) throw new Error('This project was removed from Recent Projects. Open its folder to add it again.');
  const sharedMain = await readMainSelection(root);
  const mainInput = main ?? (sharedMain === undefined ? saved?.main : sharedMain);
  let mainFile = null;
  if (mainInput !== undefined && mainInput !== null) {
    try {
      if (!mainInput) throw new Error('--main must point to a project .tex or .ltx file.');
      mainFile = await projectPath(root, mainInput);
      if (!isTeX(mainFile) || !(await fs.stat(mainFile)).isFile()) {
        throw new Error('--main must point to a project .tex or .ltx file.');
      }
    } catch (error) {
      if (main !== undefined) throw error;
      mainFile = null;
    }
  }

  if (main !== undefined) {
    await saveMainSelection(root, path.relative(root, mainFile).split(path.sep).join('/'));
  }
  mainFile ??= await findMain(root, initial);
  const [entries, initialPDF] = await Promise.all([projectEntries(root, root), readSharedPDF(root, mainFile)]);
  return {root, initial: initial ?? mainFile, mainFile, initialPDF, entries, session: initial ? null : saved,
    autosaveDelay, removedAtOnOpen};
}

async function availableSessions() {
  const sessions = await listSessions();
  const available = await Promise.all(sessions.map(async session => {
    try {
      return await fs.realpath(session.root) === session.root && (await fs.stat(session.root)).isDirectory();
    } catch {
      return false;
    }
  }));
  return sessions.filter((_, index) => available[index]);
}

async function main() {
  const args = process.argv.slice(2);
  const resume = args[0] === 'resume';
  if (resume) args.shift();
  const {values, positionals} = parseArgs({
    args,
    options: {
      help: {type: 'boolean', short: 'h'},
      'no-mouse': {type: 'boolean'},
      'no-autosave': {type: 'boolean'},
      'autosave-delay': {type: 'string', default: '1000'},
      ...(resume ? {last: {type: 'boolean'}} : {main: {type: 'string'}}),
    },
    allowPositionals: !resume,
  });
  if (values.help) {
    console.log(help);
    return;
  }
  if (positionals.length > 1) throw new Error('Pass one project folder or source file. Use --help for usage.');
  const delay = Number(values['autosave-delay']);
  if (!/^\d+$/.test(values['autosave-delay']) || delay < 1000 || delay > 2_147_483_647) {
    throw new Error('--autosave-delay must be an integer from 1000 to 2147483647 ms.');
  }
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Run PageQuoin in an interactive terminal.');
  const autosaveDelay = values['no-autosave'] ? null : delay;

  let screen;
  if (resume) {
    const sessions = values.last ? await availableSessions() : await listSessions();
    if (!sessions.length) {
      console.log('No recent projects to resume. Run pq from a project folder first.');
      return;
    }
    const open = session => loadProject(session.root, {session, autosaveDelay});
    screen = values.last
      ? React.createElement(App, await open(sessions[0]))
      : React.createElement(ResumePicker, {sessions, open, remove: session => removeSession(session.root)});
  } else {
    screen = React.createElement(App, await loadProject(positionals[0] ?? process.cwd(), {main: values.main, autosaveDelay}));
  }

  const app = values['no-mouse'] ? screen : React.createElement(MouseTracking, null, screen);
  const {waitUntilExit} = render(app, {alternateScreen: true, exitOnCtrlC: false});
  const result = await waitUntilExit();
  if (typeof result === 'string') console.error('PageQuoin: ' + result.replace(/\p{Cc}/gu, ' '));
}

try {
  await main();
} catch (error) {
  console.error('PageQuoin: ' + error.message.replace(/\p{Cc}/gu, ' '));
  process.exitCode = 1;
}

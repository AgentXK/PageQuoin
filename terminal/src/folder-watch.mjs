import {watch} from 'node:fs';

const refreshDelay = 100;
const fallbackDelay = 1000;

export function watchProjectFolder(folder, onChange) {
  let disposed = false;
  let watcher;
  let refreshTimer;
  let fallbackTimer;

  function scheduleRefresh() {
    if (disposed || refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = undefined;
      onChange();
    }, refreshDelay);
    refreshTimer.unref();
  }

  function startFallback() {
    if (disposed || fallbackTimer) return;
    fallbackTimer = setInterval(scheduleRefresh, fallbackDelay);
    fallbackTimer.unref();
    watcher?.close();
    watcher = undefined;
    scheduleRefresh();
  }

  try {
    watcher = watch(folder, {persistent: false}, scheduleRefresh);
    watcher.on('error', startFallback);
    watcher.on('close', startFallback);
  } catch {
    startFallback();
  }
  // A file can change between the initial listing and starting the watcher.
  scheduleRefresh();

  return () => {
    disposed = true;
    clearTimeout(refreshTimer);
    clearInterval(fallbackTimer);
    watcher?.close();
    watcher = undefined;
  };
}

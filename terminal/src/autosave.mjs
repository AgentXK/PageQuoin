export function createAutosave({delay = 1000, write, onSaved, onError}) {
  const entries = new Map();
  const pending = new Set();
  let disposed = false;

  function entryFor(tab) {
    let entry = entries.get(tab);
    if (!entry) {
      entry = {};
      entries.set(tab, entry);
    }
    return entry;
  }

  function release(tab, entry) {
    if (!entry.timer && !entry.tail) entries.delete(tab);
  }

  function invalidate(entry) {
    clearTimeout(entry.timer);
    entry.timer = undefined;
    entry.request = undefined;
  }

  function enqueue(tab, entry, request) {
    const result = (entry.tail ?? Promise.resolve()).then(async () => {
      if ((request && entry.request !== request) || !tab.dirty) return;
      try {
        await write(tab);
      } catch (error) {
        if (!request) throw error;
        if (entry.request === request) onError?.(tab, error);
        return;
      }
      if (request && entry.request === request) onSaved?.(tab);
    });
    const tail = result.catch(() => {});
    entry.tail = tail;
    pending.add(tail);
    void tail.then(() => {
      pending.delete(tail);
      if (entry.tail === tail) entry.tail = undefined;
      release(tab, entry);
    });
    return result;
  }

  return {
    schedule(tab) {
      if (disposed || delay === null) return;
      const entry = entryFor(tab);
      invalidate(entry);
      if (!tab.dirty) {
        release(tab, entry);
        return;
      }
      const request = {};
      entry.request = request;
      entry.timer = setTimeout(() => {
        entry.timer = undefined;
        void enqueue(tab, entry, request);
      }, delay);
    },

    async save(tab) {
      if (disposed || !tab) return;
      const entry = entryFor(tab);
      invalidate(entry);
      await enqueue(tab, entry);
    },

    cancel(tab) {
      const entry = entries.get(tab);
      if (!entry) return;
      invalidate(entry);
      release(tab, entry);
    },

    async idle() {
      await Promise.all(pending);
    },

    dispose() {
      disposed = true;
      for (const [tab, entry] of entries) {
        invalidate(entry);
        release(tab, entry);
      }
    },
  };
}

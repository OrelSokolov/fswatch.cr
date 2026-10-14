# fswatch.cr

Cross-platform filesystem watching for Crystal. Port & adapters core
with native event backends and a universal polling fallback.
**Inspired by [fswatch / libfswatch](https://github.com/emcrisostomo/fswatch)
by Enrico M. Crisostomo** — the event model follows its
Created/Removed/Moved/Updated/IsDir flags; this is an independent
pure-Crystal implementation with **no C dependency**.

```crystal
require "fswatch"

watch = FSWatch.watch("src") do |event|
  if event.created?
    puts "new: #{event.path}"
  elsif event.deleted?
    puts "gone: #{event.path}"
  end
end

# ... later
watch.stop
```

## Backends

| Platform     | Backend   | Notes                                             |
|--------------|-----------|---------------------------------------------------|
| Linux        | `Inotify` | native libc bindings, evented fiber, tested       |
| macOS, *BSD  | `Kqueue`  | EVFILT_VNODE, **experimental** (see below)        |
| any          | `Poll`    | snapshot diff over `interval` (default 1s), fallback |

The backend is chosen at compile time; `FSWatch::Poll` can also be
driven directly (it satisfies the same `Backend` interface as the
core uses).

## Threading model

The observation loop is a **Crystal fiber**, not an OS thread: the
backend fd is registered with the event loop (epoll/kqueue) and the
fiber suspends in `read`/`wait_readable`, waking only on events.
Consequences:

- no foreign threads ever call into Crystal — handlers run on the
  cooperative scheduler and may touch any Crystal state freely;
- idle cost is zero (no polling, no spinning);
- the host program must run the scheduler the usual Crystal way —
  a program that never yields (e.g. a blocking C event loop) gets no
  events until it does.

Crystal's `Thread` requires `-Dpreview_mt` and is therefore not used
by this shard.

## Platform caveats

- **inotify** (as documented by libfswatch too): not recursive — the
  backend arms a watch per directory; children born between a
  directory's creation and the watch being armed are not reported.
  Network filesystems are not covered; the kernel queue can overflow
  (delivered as an `Overflow` event — rescan any caches).
- **kqueue** (experimental, not yet CI-tested): a directory's
  `NOTE_WRITE` carries no child name, so directory events are coarse
  (Modified on the directory itself); recursion keeps the watch set
  in step but events stay unnamed. Exact for watched files.
- **poll**: moves are reported as Deleted + Created; metadata-only
  changes are not reported; latency = `interval:`.

## Symlinks

Symlinked directories are watched as leaves and never descended —
a symlink loop would otherwise grow the walk/watch set forever.

## License

MIT. The event-model inspiration, libfswatch, is dual-licensed
GPL-3.0/Apache-2.0 by its author.

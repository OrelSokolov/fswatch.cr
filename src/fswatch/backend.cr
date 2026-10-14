# fswatch.cr — the PORT half of port & adapters: what every backend
# promises the core. Backends translate their platform's native
# events into `Event`s and push them out through `#emit`; they own
# their own state and observation loop (`#run`, spawned on a fiber
# by the core) and their own stop path.

module FSWatch
  abstract class Backend
    # Begin watching *path* (a file or a directory). With `recursive`
    # set at construction, backends extend the watch to the tree —
    # natively where the API allows (inotify: add a watch per
    # directory on create; kqueue: rescan on directory NOTE_WRITE;
    # poll: the tree walk is the watch).
    abstract def add(path : String) : Nil

    # Stop watching *path* (and, for directories, its subtree).
    abstract def remove(path : String) : Nil

    # The observation loop — runs INSIDE a fiber spawned by the core;
    # returns when stopped. Must never block the scheduler thread:
    # waits go through the event loop (evented IO / sleep / select).
    abstract def run : Nil

    # Request teardown; must be callable from any fiber. The run loop
    # may take a bounded moment (stop-check cadence) to actually exit.
    abstract def stop : Nil

    # Subclasses capture the handler as @emit (their constructors
    # take `&@emit : Event ->`); this forwards a native event up.
    protected def emit(event : Event) : Nil
      @emit.call(event)
    end
  end
end

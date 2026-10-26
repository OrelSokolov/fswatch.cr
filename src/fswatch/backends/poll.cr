# fswatch.cr — the universal backend: a periodic snapshot diff.
# Works on any platform Crystal's Dir/File reach (including win32),
# needs no kernel support, and serves as the fallback when a native
# backend is unavailable or fails (watch-table limits, permissions).
#
# Granularity is coarser than the event backends: moves are reported
# as a Deleted + Created pair (a poller cannot see rename cookies),
# metadata-only changes are NOT reported (the snapshot keys on
# mtime), and latency is the interval.

module FSWatch
  class Poll < Backend
    DEFAULT_INTERVAL = 1.second

    # How the tree looked last tick: path => {mtime, dir?}.
    private record Snap, mtime : Time?, dir : Bool

    @interval : Time::Span
    @roots = [] of String
    @snapshot = {} of String => Snap
    @skip : (String -> Bool)?
    @stopped = Atomic(Bool).new(false)
    @wake = Channel(Nil).new

    def initialize(@recursive : Bool, interval : Time::Span? = nil,
                   skip : (String -> Bool)? = nil, &@emit : Event ->)
      @interval = interval || DEFAULT_INTERVAL
      @skip = skip
    end

    def add(path : String) : Nil
      path = File.expand_path(path)
      @roots << path unless @roots.includes?(path)
    end

    def remove(path : String) : Nil
      path = File.expand_path(path)
      @roots.reject! { |r| r == path }
      # Drop the subtree from the baseline so the next diff does not
      # report the unwatched paths as deleted.
      prefix = path.ends_with?(File::SEPARATOR) ? path : path + File::SEPARATOR
      @snapshot.each_key.reject { |p| p == path || p.starts_with?(prefix) }
        .to_a.each { |p| @snapshot.delete(p) }
      @snapshot.delete(path)
    end

    def run : Nil
      loop do
        break if @stopped.get
        current = scan
        diff(@snapshot, current).each { |event| emit event }
        @snapshot = current
        break if @stopped.get
        select
        when @wake.receive? # stop() closed the channel — bail now
          break
        when timeout(@interval)
        end
      end
    ensure
      @snapshot.clear
    end

    def stop : Nil
      @stopped.set(true)
      @wake.close
    end

    # --- internals --------------------------------------------------

    private def scan : Hash(String, Snap)
      current = {} of String => Snap
      @roots.each { |root| snap(root, current) }
      current
    end

    # linfo (not info): a symlink is snapshotted as a leaf and never
    # descended — a symlink loop would otherwise grow the walk forever.
    # Skip-filtered children are neither snapshotted nor descended.
    private def snap(path : String, current : Hash(String, Snap)) : Nil
      info = File.info?(path, follow_symlinks: false)
      return unless info
      dir = info.type.directory?
      current[path] = Snap.new(info.modification_time, dir)
      return unless @recursive && dir
      budget = 256 # share the scheduler on huge trees
      begin
        Dir.each_child(path) do |name|
          child = File.join(path, name)
          next if @skip.try &.call(child)
          snap(child, current)
          budget -= 1
          if budget.zero?
            budget = 256
            Fiber.yield
          end
        end
      rescue File::NotFoundError | File::AccessDeniedError
        # raced away or unreadable — what we have is the snapshot
      end
    end

    private def diff(before : Hash(String, Snap),
                     after : Hash(String, Snap)) : Array(Event)
      events = [] of Event
      after.each do |path, snap|
        if (old = before[path]?)
          unless old.mtime == snap.mtime
            flags = Event::Flag::Modified
            flags |= Event::Flag::IsDir if snap.dir
            events << Event.new(path, flags)
          end
        else
          flags = Event::Flag::Created
          flags |= Event::Flag::IsDir if snap.dir
          events << Event.new(path, flags)
        end
      end
      before.each do |path, snap|
        next if after.has_key?(path)
        flags = Event::Flag::Deleted
        flags |= Event::Flag::IsDir if snap.dir
        events << Event.new(path, flags)
      end
      events
    end
  end
end

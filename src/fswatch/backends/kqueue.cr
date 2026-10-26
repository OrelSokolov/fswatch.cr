# fswatch.cr — macOS/*BSD backend: kqueue EVFILT_VNODE.
#
# EXPERIMENTAL: developed against the kqueue(2) man pages and the
# libfswatch kqueue monitor's approach; not yet exercised on a
# macOS/BSD CI runner. Treat as a starting point, test before
# relying on it — or pass the Poll backend explicitly.
#
# Model: one vnode watch (open fd + EV_ADD) per watched path. Unlike
# inotify, a directory's NOTE_WRITE carries NO child name — the event
# says "this directory changed" — so directory events are coarse:
#   * a watched DIRECTORY reports Modified on any child change;
#   * recursion keeps the watch set in step (NOTE_WRITE triggers a
#     rescan that arms watches for new directories), but the events
#     still won't name individual children.
# File events (Modified/Attrib/Deleted on the file itself) are exact.
# This is the fundamental kqueue trade-off libfswatch documents too.

{% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) %}
  # The stdlib already binds kqueue(2)/kevent(2) in LibC on every
  # kqueue platform (lib_c/*/c/sys/event.cr, with Kevent/Timespec
  # structs) — redeclaring them in a private lib is a hard Crystal
  # "fun redefinition with different signature" error, so this
  # backend rides LibC. The aliases paper over the Kevent/KEvent
  # naming and keep the class's identifiers below unchanged.
  alias KEvent = LibC::Kevent
  alias KQTimespec = LibC::Timespec
{% end %}

module FSWatch
  {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) %}
    class Kqueue < Backend
      EV_ADD      =  0x1_u16
      EV_DELETE   =  0x2_u16
      EV_CLEAR    = 0x20_u16
      EV_ERROR    = 0x4000_u16
      EVFILT_VNODE = -8_i16

      NOTE_DELETE = 0x1_u32
      NOTE_WRITE  = 0x2_u32
      NOTE_EXTEND = 0x4_u32
      NOTE_ATTRIB = 0x8_u32
      NOTE_LINK   = 0x10_u32
      NOTE_RENAME = 0x20_u32
      NOTE_REVOKE = 0x40_u32
      NOTE_ALL    = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB |
                    NOTE_LINK | NOTE_RENAME | NOTE_REVOKE

      # O_EVFLAG differs per BSD (darwin 0x2000, freebsd 0x8000); the
      # fd is never read — kevent(2) is the interface — so the flag is
      # advisory. Fall back to O_RDONLY where unknown.
      O_EVFLAG = {% if flag?(:darwin) %}
        0x2000
      {% elsif flag?(:freebsd) %}
        0x8000
      {% else %}
        0x0
      {% end %}

      STOP_CADENCE = 0.5.seconds

      @kq : Int32
      @kq_io : IO::FileDescriptor
      @fd_paths = {} of Int32 => String
      @path_fds = {} of String => Int32
      @skip : (String -> Bool)?
      @stopped = Atomic(Bool).new(false)
      # A zeroed timespec: kevent as a pure drain call.
      @zero_timeout = KQTimespec.new(tv_sec: 0, tv_nsec: 0)

      def initialize(@recursive : Bool, interval : Time::Span? = nil,
                     skip : (String -> Bool)? = nil, &@emit : Event ->)
        @skip = skip
        kq = sys_kqueue
        raise IO::Error.new("kqueue(2) failed") if kq < 0
        @kq = kq
        io = IO::FileDescriptor.new(kq)
        # See the inotify backend: the fd-type probe would clear the
        # kqueue fd's O_NONBLOCK and wedge the scheduler thread.
        IO::FileDescriptor.set_blocking(kq, false)
        @kq_io = io
      end

      def add(path : String) : Nil
        return if @path_fds.has_key?(path)
        fd = sys_open(path)
        return if fd < 0
        change = KEvent.new
        change.ident = fd.to_u64
        change.filter = EVFILT_VNODE
        change.flags = EV_ADD | EV_CLEAR
        change.fflags = NOTE_ALL
        if LibC.kevent(@kq, pointerof(change), 1, nil, 0, nil) < 0
          sys_close(fd)
          return
        end
        @fd_paths[fd] = path
        @path_fds[path] = fd
        return unless @recursive
        return unless directory?(path)
        begin
          Dir.each_child(path) do |name|
            child = File.join(path, name)
            next if @skip.try &.call(child)
            add(child) if directory?(child)
          end
        rescue File::NotFoundError | File::AccessDeniedError
        end
      end

      def remove(path : String) : Nil
        if (fd = @path_fds.delete(path))
          @fd_paths.delete(fd)
          change = KEvent.new
          change.ident = fd.to_u64
          change.filter = EVFILT_VNODE
          change.flags = EV_DELETE
          LibC.kevent(@kq, pointerof(change), 1, nil, 0, nil)
          sys_close(fd)
        end
        prefix = path.ends_with?(File::SEPARATOR) ? path : path + File::SEPARATOR
        @path_fds.keys.select(&.starts_with?(prefix)).each do |sub|
          remove(sub)
        end
      end

      def run : Nil
        events = StaticArray(KEvent, 64).new { KEvent.new }
        loop do
          break if @stopped.get
          # Modern Crystal has no IO#wait_readable (the new event loops
          # keep it event-loop-side), and kevent(2) with a timeout would
          # block the whole single-threaded scheduler — so drain with a
          # zero timeout at STOP_CADENCE and sleep between rounds: the
          # poll backend's latency model (see the file header).
          sleep STOP_CADENCE
          break if @stopped.get
          loop do
            n = LibC.kevent(@kq, nil, 0, events.to_unsafe, events.size,
                            pointerof(@zero_timeout))
            break if @stopped.get || n <= 0
            n.times { |i| dispatch(events[i]) }
            break if n < events.size # queue drained
          end
        end
      ensure
        @fd_paths.each_key { |fd| sys_close(fd) }
        @fd_paths.clear
        @path_fds.clear
        @kq_io.close unless @kq_io.closed?
      end

      def stop : Nil
        @stopped.set(true)
      end

      # --- internals --------------------------------------------------

      # kqueue(2): darwin's LibC binds plain kqueue(), the BSDs bind
      # kqueue1(flags); open(2)/close(2) are LibC's own everywhere.
      private def sys_kqueue : Int32
        {% if flag?(:darwin) %}
          LibC.kqueue.to_i32
        {% else %}
          LibC.kqueue1(0)
        {% end %}
      end

      private def sys_open(path : String) : Int32
        LibC.open(path, O_EVFLAG).to_i32
      end

      private def sys_close(fd : Int32) : Nil
        LibC.close(fd)
      end

      private def dispatch(ev : KEvent) : Nil
        return unless (path = @fd_paths[ev.ident.to_i32]?)
        fflags = ev.fflags
        return if fflags.zero? || (ev.flags & EV_ERROR) != 0

        flags = Event::Flag::None
        flags |= Event::Flag::Deleted if fflags & NOTE_DELETE != 0
        flags |= Event::Flag::Modified if (fflags & NOTE_WRITE) != 0 ||
                                          (fflags & NOTE_EXTEND) != 0
        flags |= Event::Flag::Attrib if fflags & NOTE_ATTRIB != 0
        flags |= Event::Flag::SelfRemoved if (fflags & NOTE_RENAME) != 0 ||
                                             (fflags & NOTE_REVOKE) != 0
        if directory?(path)
          flags |= Event::Flag::IsDir
          # Coarse (see the file header): a directory event with no
          # child name — the tree-level signal poll/notify users get.
        end

        if fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE) != 0
          remove(path)
        elsif @recursive && (fflags & NOTE_WRITE) != 0 && directory?(path)
          rescan(path) # arm watches for directories born under `path`
        end
        emit Event.new(path, flags) unless flags.none?
      end

      private def rescan(path : String) : Nil
        begin
          Dir.each_child(path) do |name|
            child = File.join(path, name)
            next if @skip.try &.call(child)
            add(child) unless @path_fds.has_key?(child)
          end
        rescue File::NotFoundError | File::AccessDeniedError
        end
      end

      private def directory?(path : String) : Bool
        if (info = File.info?(path, follow_symlinks: false))
          info.type.directory?
        else
          false
        end
      rescue File::AccessDeniedError
        false
      end
    end
  {% end %}
end

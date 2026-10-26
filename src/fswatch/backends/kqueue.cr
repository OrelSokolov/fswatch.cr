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
  @[Link("c")]
  lib LibKEvent
    fun kqueue = kqueue : Int32
    fun kevent = kevent(kq : Int32, changelist : KEvent*, nchanges : Int32,
                        eventlist : KEvent*, nevents : Int32,
                        timeout : Timespec*) : Int32
    fun kq_open = open(path : UInt8*, oflag : Int32, ...) : Int32
    fun kq_close = close(fd : Int32) : Int32

    struct KEvent
      ident : UInt64  # uintptr_t — the fd for EVFILT_VNODE
      filter : Int16  # EVFILT_VNODE
      flags : UInt16  # EV_ADD/EV_DELETE/EV_CLEAR/EV_ERROR
      fflags : UInt32 # NOTE_* bits
      data : Int64
      udata : Void*
    end

    struct Timespec
      tv_sec : Int64
      tv_nsec : Int64
    end
  end
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
      @zero_timeout = LibKEvent::Timespec.new(tv_sec: 0, tv_nsec: 0)

      def initialize(@recursive : Bool, interval : Time::Span? = nil,
                     skip : (String -> Bool)? = nil, &@emit : Event ->)
        @skip = skip
        kq = LibKEvent.kqueue
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
        fd = LibKEvent.kq_open(path, O_EVFLAG)
        return if fd < 0
        change = LibKEvent::KEvent.new
        change.ident = fd.to_u64
        change.filter = EVFILT_VNODE
        change.flags = EV_ADD | EV_CLEAR
        change.fflags = NOTE_ALL
        if LibKEvent.kevent(@kq, pointerof(change), 1, nil, 0, nil) < 0
          LibKEvent.kq_close(fd)
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
          change = LibKEvent::KEvent.new
          change.ident = fd.to_u64
          change.filter = EVFILT_VNODE
          change.flags = EV_DELETE
          LibKEvent.kevent(@kq, pointerof(change), 1, nil, 0, nil)
          LibKEvent.kq_close(fd)
        end
        prefix = path.ends_with?(File::SEPARATOR) ? path : path + File::SEPARATOR
        @path_fds.keys.select(&.starts_with?(prefix)).each do |sub|
          remove(sub)
        end
      end

      def run : Nil
        io = @kq_io
        events = StaticArray(LibKEvent::KEvent, 64).new { LibKEvent::KEvent.new }
        loop do
          break if @stopped.get
          # The kqueue fd is readable exactly when events are pending:
          # sleep on the event loop (not the thread) until then.
          io.wait_readable(STOP_CADENCE)
          break if @stopped.get
          n = LibKEvent.kevent(@kq, nil, 0, events.to_unsafe, events.size,
            pointerof(@zero_timeout))
          break if n < 0
          events[0, n].each { |ev| dispatch(ev) }
        end
      ensure
        @fd_paths.each_key { |fd| LibKEvent.kq_close(fd) }
        @fd_paths.clear
        @path_fds.clear
        @kq_io.close unless @kq_io.closed?
      end

      def stop : Nil
        @stopped.set(true)
      end

      # --- internals --------------------------------------------------

      private def dispatch(ev : LibKEvent::KEvent) : Nil
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

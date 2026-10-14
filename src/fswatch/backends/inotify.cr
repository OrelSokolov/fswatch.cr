# fswatch.cr — Linux backend: inotify through plain libc wrappers
# (no shard, no C shim). One inotify fd for the whole backend; the
# observation fiber evented-reads it (epoll) and decodes records.
#
# Recursion: inotify is not recursive, so `add` walks the tree adding
# a watch per directory, and Created/MovedTo + IsDir events add
# watches for directories that appear later. Known inotify race
# (documented by libfswatch too): children born between a
# directory's creation and the watch being armed are not reported.

{% if flag?(:linux) %}
  @[Link("c")]
  lib LibInotify
    fun init1 = inotify_init1(flags : Int32) : Int32
    fun add_watch = inotify_add_watch(fd : Int32, pathname : UInt8*,
                                      mask : UInt32) : Int32
    fun rm_watch = inotify_rm_watch(fd : Int32, wd : Int32) : Int32
  end
{% end %}

module FSWatch
  {% if flag?(:linux) %}
    class Inotify < Backend
      # Event masks (inotify(7)).
      IN_MODIFY      =         0x2_u32
      IN_ATTRIB      =         0x4_u32
      IN_MOVED_FROM  =        0x40_u32
      IN_MOVED_TO    =        0x80_u32
      IN_CREATE      =       0x100_u32
      IN_DELETE      =       0x200_u32
      IN_DELETE_SELF =       0x400_u32
      IN_MOVE_SELF   =       0x800_u32
      IN_Q_OVERFLOW  =      0x4000_u32
      IN_IGNORED     =      0x8000_u32
      IN_ISDIR       = 0x4000_0000_u32
      IN_NONBLOCK    =          0o4000
      IN_CLOEXEC     =       0o2000000

      WATCH_MASK = IN_MODIFY | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO |
                   IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF

      # How often the read loop re-checks @stopped: the evented read
      # carries a read_timeout so a stopped backend still exits
      # promptly instead of sleeping until the next event.
      STOP_CADENCE = 0.5.seconds

      @io : IO::FileDescriptor
      @wd_paths = {} of Int32 => String
      @path_wds = {} of String => Int32
      @stopped = Atomic(Bool).new(false)

      def initialize(@recursive : Bool, interval : Time::Span? = nil,
                     &@emit : Event ->)
        fd = LibInotify.init1(IN_NONBLOCK | IN_CLOEXEC)
        raise IO::Error.new("inotify_init1(2) failed") if fd < 0
        io = IO::FileDescriptor.new(fd)
        # The constructor's fd-type probe doesn't know inotify fds (an
        # anon inode is neither pipe nor socket) so it assumes blocking
        # — and CLEARS the fd's O_NONBLOCK, which would wedge the
        # scheduler thread in read. Re-arm: the evented read then
        # suspends the fiber on EAGAIN (epoll) instead.
        IO::FileDescriptor.set_blocking(fd, false)
        @io = io
      end

      def add(path : String) : Nil
        arm(path, report: false)
      end

      # A directory discovered at RUNTIME (a Created/MovedTo event):
      # arms the subtree like `add`, but the walk also reports the
      # children it finds — closing inotify's arming race (children
      # born between the mkdir and the arming get no kernel event;
      # e.g. a rapid mkdir -p a/b/c burst). Rare duplicates with
      # kernel events are possible; a missing file is worse than a
      # repeated one (the trade-off libfswatch documents too).
      private def add_discovered(path : String) : Nil
        arm(path, report: true)
      end

      private def arm(path : String, report : Bool) : Nil
        return if @path_wds.has_key?(path)
        wd = LibInotify.add_watch(@io.fd, path, WATCH_MASK)
        return if wd < 0 # permissions, watch-table full, vanished
        @wd_paths[wd] = path
        @path_wds[path] = wd
        return unless @recursive
        return unless directory?(path)
        begin
          Dir.each_child(path) do |name|
            child = File.join(path, name)
            dir = directory?(child)
            if report
              flags = Event::Flag::Created
              flags |= Event::Flag::IsDir if dir
              emit Event.new(child, flags)
            end
            arm(child, report) if dir
          end
        rescue File::NotFoundError | File::AccessDeniedError
          # raced away or unreadable — the watch on the parent stands
        end
      end

      def remove(path : String) : Nil
        if (wd = @path_wds.delete(path))
          @wd_paths.delete(wd)
          LibInotify.rm_watch(@io.fd, wd)
        end
        prefix = path.ends_with?(File::SEPARATOR) ? path : path + File::SEPARATOR
        @path_wds.keys.select(&.starts_with?(prefix)).each do |sub|
          remove(sub)
        end
      end

      def run : Nil
        io = @io
        io.read_timeout = STOP_CADENCE
        header = Bytes.new(16) # wd, mask, cookie, len (inotify(7))
        loop do
          break if @stopped.get
          begin
            break unless io.read_fully?(header)
          rescue IO::TimeoutError
            next # stop-check cadence
          end
          break unless decode(io, header)
        end
      ensure
        @wd_paths.clear
        @path_wds.clear
        @io.close unless @io.closed?
      end

      def stop : Nil
        @stopped.set(true)
      end

      # --- internals --------------------------------------------------

      # Reads one record's name slot and dispatches. False = stream
      # over (EOF) — the caller exits.
      private def decode(io : IO::FileDescriptor, header : Bytes) : Bool
        wd = IO::ByteFormat::SystemEndian.decode(Int32, header[0, 4])
        mask = IO::ByteFormat::SystemEndian.decode(UInt32, header[4, 4])
        len = IO::ByteFormat::SystemEndian.decode(UInt32,
          header[12, 4]).to_i
        name_slice = Bytes.new(len) # NUL-padded, consumed in full
        return false unless io.read_fully?(name_slice)

        if mask & IN_Q_OVERFLOW != 0
          emit Event.new("", Event::Flag::Overflow)
          return true
        end
        return true unless (base = @wd_paths[wd]?)

        if mask & IN_IGNORED != 0 # watch reaped (rm_watch / path gone)
          @path_wds.delete(base)
          @wd_paths.delete(wd)
          return true
        end

        flags = Event::Flag::None
        flags |= Event::Flag::IsDir if mask & IN_ISDIR != 0
        flags |= Event::Flag::Created if mask & IN_CREATE != 0
        flags |= Event::Flag::Deleted if mask & IN_DELETE != 0
        flags |= Event::Flag::MovedFrom if mask & IN_MOVED_FROM != 0
        flags |= Event::Flag::MovedTo if mask & IN_MOVED_TO != 0
        flags |= Event::Flag::Modified if mask & IN_MODIFY != 0
        flags |= Event::Flag::Attrib if mask & IN_ATTRIB != 0
        if mask & (IN_DELETE_SELF | IN_MOVE_SELF) != 0
          flags |= Event::Flag::SelfRemoved | Event::Flag::Deleted
        end
        return true if flags.none?

        # len 0 = an event on the watched path itself (SELF/MOVE_SELF);
        # otherwise the name is NUL-terminated inside the slot.
        name = len.zero? ? "" : String.new(name_slice.to_unsafe)
        path = name.empty? ? base : File.join(base, name)
        emit Event.new(path, flags)

        # Keep the watch set in step with the tree (recursion): a new
        # directory needs a watch; a gone one releases its subtree.
        if @recursive && flags.includes?(Event::Flag::IsDir)
          if (flags.includes?(Event::Flag::Created) ||
             flags.includes?(Event::Flag::MovedTo)) && directory?(path)
            add_discovered(path)
          elsif flags.includes?(Event::Flag::Deleted) ||
                flags.includes?(Event::Flag::MovedFrom)
            remove(path)
          end
        end
        true
      end

      # linfo (not info): a symlink to a directory is NOT descended —
      # otherwise a symlink loop could grow the watch set forever.
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

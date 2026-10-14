# fswatch.cr — the normalized event every backend emits.

module FSWatch
  struct Event
    # Bit flags in the fswatch spirit (Created/Removed/MovedTo/...).
    # A single event may combine them (e.g. `Created | IsDir`).
    @[Flags]
    enum Flag
      Created     # a file or directory came into existence
      Deleted     # ... was removed
      MovedFrom   # rename/move source side
      MovedTo     # rename/move destination side
      Modified    # content written
      Attrib      # metadata changed (mtime, permissions, ...)
      IsDir       # the subject of the event is a directory
      SelfRemoved # a WATCHED path itself was deleted/renamed away
      Overflow    # the kernel event queue overflowed; state may be
      # stale — rescan anything you cache
    end

    getter path : String
    getter flags : Flag

    def initialize(@path : String, @flags : Flag = Flag::None)
    end

    def created? : Bool
      flags.includes?(Flag::Created)
    end

    def deleted? : Bool
      flags.includes?(Flag::Deleted)
    end

    def moved_from? : Bool
      flags.includes?(Flag::MovedFrom)
    end

    def moved_to? : Bool
      flags.includes?(Flag::MovedTo)
    end

    def modified? : Bool
      flags.includes?(Flag::Modified)
    end

    def attrib? : Bool
      flags.includes?(Flag::Attrib)
    end

    def dir? : Bool
      flags.includes?(Flag::IsDir)
    end

    def self_removed? : Bool
      flags.includes?(Flag::SelfRemoved)
    end

    def overflow? : Bool
      flags.includes?(Flag::Overflow)
    end

    def to_s(io : IO) : Nil
      io << "FSWatch::Event("
      first = true
      names = {Flag::Created => "created", Flag::Deleted => "deleted",
               Flag::MovedFrom => "moved_from", Flag::MovedTo => "moved_to",
               Flag::Modified => "modified", Flag::Attrib => "attrib",
               Flag::IsDir => "dir", Flag::SelfRemoved => "self_removed",
               Flag::Overflow => "overflow"}
      names.each do |flag, name|
        if flags.includes?(flag)
          io << " | " unless first
          io << name
          first = false
        end
      end
      io << " @ " << path << ')'
    end
  end
end

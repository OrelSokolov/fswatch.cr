# fswatch.cr — the core: owns the user handler, picks the platform
# backend at compile time, feeds it the root path and its observation
# fiber, and gates delivery on `#stop`.

module FSWatch
  class Watch
    getter path : String
    getter? recursive : Bool

    @handler : Event ->
    @backend : Backend
    @stopped = Atomic(Bool).new(false)

    def initialize(path : String, *, recursive : Bool = true,
                   interval : Time::Span? = nil, &handler : Event ->)
      @path = File.expand_path(path)
      @recursive = recursive
      @handler = handler
      @backend = self.class.select_backend.new(@recursive, interval) do |event|
        @handler.call(event) unless @stopped.get
      end
      @backend.add(@path)
      # The observation fiber — no OS thread, see the shard header.
      # The scheduler runs it as soon as the constructing fiber
      # yields; a host that never yields never gets events (same
      # contract as any Crystal concurrency).
      spawn(name: "fswatch-backend") { @backend.run }
    end

    # Tear the watch down. Idempotent. Event delivery stops
    # immediately; the backend fiber winds down within its
    # stop-check cadence (0.5s).
    def stop : Nil
      @stopped.set(true)
      @backend.stop
    end

    def stopped? : Bool
      @stopped.get
    end

    # The adapter table. Keep the guard list in sync with the
    # requires in src/fswatch.cr.
    def self.select_backend : Backend.class
      {% if flag?(:linux) %}
        Inotify
      {% elsif flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) %}
        Kqueue
      {% else %}
        Poll
      {% end %}
    end
  end
end

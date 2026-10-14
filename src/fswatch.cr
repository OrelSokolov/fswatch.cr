# fswatch.cr — cross-platform filesystem watching for Crystal.
#
# Port & adapters: a small core (`FSWatch::Watch`) dispatches
# normalized `FSWatch::Event`s produced by a per-platform backend
# picked at compile time:
#
#   Linux        — Inotify  (native libc bindings, evented fiber)
#   macOS/*BSD   — Kqueue   (EVFILT_VNODE; EXPERIMENTAL)
#   everything   — Poll     (snapshot diff over an interval; also the
#                            fallback on unsupported platforms and on
#                            backend failures such as watch limits)
#
# The observation loop is a Crystal FIBER, not an OS thread: the
# backend fd is registered with the event loop (epoll/kqueue), the
# fiber suspends in `read`/`wait_readable` and wakes only on events —
# so no foreign threads ever call back into Crystal and user handlers
# run on the cooperative scheduler, safe to touch any Crystal state.
# (Crystal's `Thread` requires -Dpreview_mt and is unsuitable for a
# reusable shard; a fiber is the runtime-native equivalent.)
#
# Event model inspired by fswatch/libfswatch by Enrico M. Crisostomo
# (https://github.com/emcrisostomo/fswatch) — Created/Removed/Moved/
# Updated/IsDir flags — re-implemented for Crystal, no C dependency.
#
# Usage:
#
#   require "fswatch"
#
#   watch = FSWatch.watch("src") do |event|
#     puts "#{event.path} #{event.flags}" if event.created?
#   end
#   # ... later:
#   watch.stop

require "./fswatch/event"
require "./fswatch/backend"
require "./fswatch/watch"
require "./fswatch/backends/poll"
{% if flag?(:linux) %}
  require "./fswatch/backends/inotify"
{% end %}
{% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) %}
  require "./fswatch/backends/kqueue"
{% end %}

module FSWatch
  VERSION = "0.1.0"

  # Watch *path* (a file or a directory; by default the whole tree
  # recursively) and yield every change event to *handler*.
  #
  # `interval:` configures the Poll backend's tick (other backends
  # ignore it). Returns a `Watch` handle; call `#stop` to tear down.
  def self.watch(path : String, *, recursive : Bool = true,
                 interval : Time::Span? = nil, &handler : Event ->) : Watch
    Watch.new(path, recursive: recursive, interval: interval, &handler)
  end
end

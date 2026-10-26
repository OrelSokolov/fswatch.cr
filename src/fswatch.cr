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
#
# `skip:` keeps a subtree off the watch tables entirely (no watch, no
# descent, no events from it):
#
#   FSWatch.watch("proj", skip: ->(p : String) { p.includes?("/node_modules/") }) do |e|
#     # ...
#   end
#
# The watched ROOT is always armed synchronously; the recursive arming
# of the tree beneath it runs on a fiber (inotify backend) — a huge
# tree delays events for its deep pre-existing directories briefly,
# never the caller.

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
  # ignore it). `skip:` receives every child directory the recursive
  # arming is about to watch (absolute path); a true return drops the
  # subtree — no watch, no descent, no events from it. Returns a
  # `Watch` handle; call `#stop` to tear down.
  def self.watch(path : String, *, recursive : Bool = true,
                 interval : Time::Span? = nil,
                 skip : (String -> Bool)? = nil,
                 &handler : Event ->) : Watch
    Watch.new(path, recursive: recursive, interval: interval, skip: skip, &handler)
  end
end

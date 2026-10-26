require "./spec_helper"

# The Watch core with the compile-time-selected backend. On Linux
# that is Inotify; the poll backend has its own dedicated spec.
describe FSWatch::Watch do
  it "delivers created/deleted/modified for the watched directory" do
    with_temp_dir do |dir|
      events = [] of FSWatch::Event
      watch = FSWatch.watch(dir) { |e| events << e }

      File.touch(File.join(dir, "a.txt"))
      eventually("create event never arrived") do
        events.any?(&.created?)
      end
      events.find(&.created?).try(&.path)
        .should eq(File.join(dir, "a.txt"))

      File.write(File.join(dir, "a.txt"), "data")
      eventually("modify event never arrived") do
        events.any?(&.modified?)
      end

      File.delete(File.join(dir, "a.txt"))
      eventually("delete event never arrived") do
        events.any?(&.deleted?)
      end
      watch.stop
    end
  end

  it "watches new subdirectories as they appear (recursive default)" do
    with_temp_dir do |dir|
      events = [] of FSWatch::Event
      watch = FSWatch.watch(dir) { |e| events << e }

      sub = File.join(dir, "sub")
      Dir.mkdir(sub)
      nested = File.join(sub, "nested")
      Dir.mkdir(nested)
      nested_file = File.join(nested, "deep.cr")
      File.touch(nested_file)

      eventually("event for a file three levels deep never arrived") do
        events.any? { |e| e.path == nested_file && e.created? }
      end
      watch.stop
    end
  end

  it "stop() halts delivery" do
    with_temp_dir do |dir|
      events = [] of FSWatch::Event
      watch = FSWatch.watch(dir) { |e| events << e }
      File.touch(File.join(dir, "warmup.txt"))
      eventually("warmup event never arrived") { !events.empty? }

      watch.stop
      watch.stopped?.should be_true
      # Let the backend fiber wind down past its stop-check cadence.
      sleep 0.7.seconds
      count = events.size
      File.touch(File.join(dir, "after-stop.txt"))
      sleep 0.3.seconds
      events.size.should eq(count)
    end
  end

  it "skips subtrees the skip filter rejects" do
    with_temp_dir do |dir|
      vendored = File.join(dir, "node_modules", "pkg")
      Dir.mkdir_p(vendored)
      hidden = File.join(dir, ".cache")
      Dir.mkdir(hidden)
      events = [] of FSWatch::Event
      watch = FSWatch.watch(dir,
        skip: ->(p : String) {
          p.includes?("node_modules") || p.includes?("/.cache")
        }) { |e| events << e }

      # The root itself stays live despite the filter.
      File.touch(File.join(dir, "top.txt"))
      eventually("top-level event never arrived") do
        events.any? { |e| e.path.ends_with?("top.txt") && e.created? }
      end

      # Skipped subtrees never raise events (bounded wait, then
      # silence is the assertion — nothing positive can arrive):
      # pre-existing ones AND one materializing at runtime (its
      # Created event on the armed root must not arm it).
      File.touch(File.join(vendored, "v.txt"))
      File.touch(File.join(hidden, "h.txt"))
      late = File.join(dir, "node_modules-late")
      Dir.mkdir(late)
      File.touch(File.join(late, "l.txt"))
      sleep 0.4.seconds
      events.any? { |e| e.path.ends_with?("v.txt") || e.path.ends_with?("h.txt") ||
                         e.path.ends_with?("l.txt") }
        .should be_false
      watch.stop
    end
  end
end

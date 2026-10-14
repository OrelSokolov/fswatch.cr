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
end

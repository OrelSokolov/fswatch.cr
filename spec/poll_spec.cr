require "./spec_helper"

# The universal fallback backend, exercised directly (the Watch core
# always picks a native backend on Linux, so Poll needs its own spec).
describe FSWatch::Poll do
  it "reports created/deleted/modified between ticks" do
    with_temp_dir do |dir|
      events = [] of FSWatch::Event
      poll = FSWatch::Poll.new(true, interval: 0.05.seconds) do |e|
        events << e
      end
      poll.add(dir)
      spawn(name: "poll-test") { poll.run }

      File.touch(File.join(dir, "a.txt"))
      eventually("create event never arrived") do
        events.any?(&.created?)
      end

      File.write(File.join(dir, "a.txt"), "changed")
      eventually("modify event never arrived") do
        events.any?(&.modified?)
      end

      File.delete(File.join(dir, "a.txt"))
      eventually("delete event never arrived") do
        events.any?(&.deleted?)
      end
      poll.stop
    end
  end

  it "walks subdirectories when recursive" do
    with_temp_dir do |dir|
      Dir.mkdir(File.join(dir, "sub"))
      events = [] of FSWatch::Event
      poll = FSWatch::Poll.new(true, interval: 0.05.seconds) do |e|
        events << e
      end
      poll.add(dir)
      spawn(name: "poll-test") { poll.run }

      deep = File.join(dir, "sub", "deep.txt")
      File.touch(deep)
      eventually("recursive create event never arrived") do
        events.any? { |e| e.path == deep && e.created? }
      end
      poll.stop
    end
  end

  it "stop() wakes the tick loop immediately" do
    with_temp_dir do |dir|
      poll = FSWatch::Poll.new(true, interval: 5.seconds) { |_e| }
      poll.add(dir)
      done = Channel(Bool).new
      spawn(name: "poll-test") do
        poll.run
        done.send(true)
      end
      sleep 0.05.seconds # let the run loop reach its first select
      poll.stop
      select
      when ok = done.receive
        ok.should be_true
      when timeout(1.second)
        fail "run loop did not exit within 1s of stop()"
      end
    end
  end
end

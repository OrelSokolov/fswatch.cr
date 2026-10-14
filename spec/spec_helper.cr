require "spec"
require "file_utils"
require "../src/fswatch"

# A Ruby-style mktempdir: unique dir under the system tempdir,
# removed after the block.
def with_temp_dir(& : String ->)
  dir = File.join(Dir.tempdir, "fswatch-spec-#{Random.new.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_r(dir) rescue nil
  end
end

# Poll `cond` every 20ms (yielding to the scheduler so the backend
# fiber runs) until it holds, or fail with *message* after *deadline*.
def eventually(message : String, deadline : Time::Span = 3.seconds,
               &cond : -> Bool) : Nil
  limit = Time.instant + deadline
  until cond.call
    raise message if Time.instant > limit
    sleep 0.02.seconds
  end
end

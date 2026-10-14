require "./spec_helper"

describe FSWatch::Event do
  it "combines flags and answers predicates" do
    e = FSWatch::Event.new("/tmp/x",
      FSWatch::Event::Flag::Created | FSWatch::Event::Flag::IsDir)
    e.created?.should be_true
    e.dir?.should be_true
    e.deleted?.should be_false
    e.modified?.should be_false
  end

  it "renders itself readably" do
    e = FSWatch::Event.new("/tmp/x",
      FSWatch::Event::Flag::Created | FSWatch::Event::Flag::IsDir)
    e.to_s.should contain("created")
    e.to_s.should contain("dir")
    e.to_s.should contain("/tmp/x")
  end
end

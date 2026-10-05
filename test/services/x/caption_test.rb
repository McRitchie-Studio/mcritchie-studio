require "test_helper"

# [unit] X::Caption — the text of a post, assembled and measured the way X
# measures it. A caption that passes here and is refused by X costs a paid call.
class X::CaptionTest < ActiveSupport::TestCase
  test "appends handles then hashtags on one tail line" do
    caption = X::Caption.new(line: "Bills by a mile.", hashtags: %w[#BillsMafia], handles: %w[@BuffaloBills])

    assert_equal "Bills by a mile.\n\n@BuffaloBills #BillsMafia", caption.text
    assert_empty caption.problems
  end

  test "does not repeat a tag the line already carries" do
    caption = X::Caption.new(line: "Go #billsmafia", hashtags: %w[#BillsMafia #NFL])

    assert_equal "Go #billsmafia\n\n#NFL", caption.text
  end

  test "an emoji weighs two and a url weighs twenty-three" do
    assert_equal 3, X::Caption.weight("a👀")
    assert_equal 25, X::Caption.weight("a https://turfmonster.media/a/very/long/path/that/is/not/counted")
  end

  test "refuses a caption over the weighted limit that String#length would pass" do
    line = "👀" * 141

    assert_operator line.length, :<, X::Caption::MAX_WEIGHT
    assert_includes X::Caption.new(line: line).problems.join, "over X's 280"
  end

  test "refuses a malformed hashtag, a malformed handle and an empty line" do
    problems = X::Caption.new(line: " ", hashtags: ["#Fly Eagles", "NFL"], handles: ["turf"]).problems.join(" | ")

    assert_includes problems, "the line is empty"
    assert_includes problems, "not a hashtag: #Fly Eagles, NFL"
    assert_includes problems, "not a handle: turf"
  end

  test "counts hashtags written into the line against the cap" do
    caption = X::Caption.new(line: "One #A #B", hashtags: %w[#C #D])

    assert_includes caption.problems.join, "4 hashtags"
  end

  test "names a link, which X bills at a higher rate" do
    assert X::Caption.new(line: "See https://turfmonster.media").link?
    refute X::Caption.new(line: "No link here").link?
  end
end

# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# [unit] No hub view comment may terminate early and leak its tail into the page.
#
# THE DEFECT. An ERB comment `<%#  %>` ends at the FIRST close sequence inside
# it. A comment that quotes an ERB tag therefore stops there, and everything
# after it renders into the page as visible prose. Nothing about the source looks
# wrong; the page simply grows a sentence.
#
# TWO SIGNATURES, because the second is structurally invisible to the first:
#   1. the comment body contains an ERB OPEN tag;
#   2. the comment quotes only a CLOSE sequence — no open tag is involved, so
#      signature 1 cannot see it. The tell is an ORPHAN close sitting between
#      this comment's end and the next ERB open: the author's own second close,
#      the mark of one comment the parser turned into two.
#
# PORTED from studio-engine's test/views/erb_comment_leak_test.rb, itself ported
# from turf-monster's erb_comment_percent_test, which carries the measured
# rationale — including the decision to ship with NO allowlist, because an
# earlier narrow attempt there was defeated by 3 false positives.
#
# MEASURED before shipping: both signatures return ZERO candidates across this
# repo's 214 view files, so this lands green and is preventive rather than a
# cleanup. This is the last of the three repos to be enrolled; the class is not
# theoretical — on the night turf's second signature shipped, it caught its own
# author writing exactly that leak into a turf view.
class ErbCommentLeakTest < ActiveSupport::TestCase
  COMMENT = /<%#(.*?)%>/m
  ERB_OPEN = "<%"
  ORPHAN_CLOSE = "%>"

  def view_root = Rails.root.join("app/views")

  def views(root = view_root) = Dir.glob(File.join(root, "**", "*.erb"))

  def rel(path, root) = path.delete_prefix("#{root}/")

  def quoting_comments(root = view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        next unless match[1].include?(ERB_OPEN)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  def leaking_comments(root = view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        # Only text between this comment's close and the NEXT ERB open can be
        # leaked prose; anything past that open belongs to another tag.
        next_open = rest.index(ERB_OPEN)
        segment = next_open ? rest[0...next_open] : rest
        next unless segment.include?(ORPHAN_CLOSE)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  test "no hub view comment quotes an ERB tag" do
    found = quoting_comments
    assert_empty found,
                 "these ERB comments contain an ERB open tag, so the comment TERMINATES on it and " \
                 "the rest of the prose renders into the page as visible text. Describe the tag " \
                 "in words, or use an HTML comment:\n  #{found.join("\n  ")}"
  end

  test "no hub view comment terminates early and leaks its tail" do
    found = leaking_comments
    assert_empty found,
                 "these ERB comments quote a CLOSE sequence, so the comment ends there and the " \
                 "rest of the sentence renders as visible text. No ERB open is involved, which " \
                 "is why the first assertion cannot see it:\n  #{found.join("\n  ")}"
  end

  # GUARD THE GUARDS. Without these the assertions above are green lights that
  # can never turn red — a matcher that stopped matching reads as a clean tree,
  # which is exactly the failure this file exists to prevent one level down.

  test "the scan recognises an ERB tag quoted inside a comment" do
    with_probe_tree do |root|
      assert_includes quoting_comments(root).join, "_leak_open.html.erb",
                      "the matcher no longer sees the very thing it exists to catch"
      refute_includes quoting_comments(root).join, "_ok.html.erb",
                      "an ordinary comment was reported — this guard would cry wolf"
    end
  end

  test "the scan recognises a comment that quotes only the close sequence" do
    with_probe_tree do |root|
      assert_includes leaking_comments(root).join, "_leak_close.html.erb"
      refute_includes leaking_comments(root).join, "_ok.html.erb",
                      "a plain percent in prose was reported as a leak"
    end
  end

  test "the guard actually reads the hub's views" do
    assert_operator views.length, :>=, 100,
                    "only #{views.length} view(s) under #{view_root} — this guard covers almost nothing"
  end

  private

  def with_probe_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "probe"))
      File.write(File.join(dir, "probe/_leak_open.html.erb"),
                 "<div>\n  <%# quoting <%= yield %> breaks this comment %>\n</div>\n")
      File.write(File.join(dir, "probe/_leak_close.html.erb"),
                 "<div>\n  <%# a comment ends at the first close sequence, which is %> and " \
                 "everything after renders %>\n</div>\n")
      File.write(File.join(dir, "probe/_ok.html.erb"),
                 "<div>\n  <%# an ordinary comment %>\n  <p>50% wide</p>\n</div>\n")
      yield dir
    end
  end
end

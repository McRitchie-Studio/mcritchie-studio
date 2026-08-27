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
# A THIRD SHAPE walked through BOTH of those, and closing it is why this file was
# touched again on 2026-08-27. When the leaked tail itself REOPENS ERB before the
# author's second close, signature 1 sees no open inside the body (the body ended
# at the first close) and signature 2, which searched only up to the next ERB open,
# never reached the orphan behind it. Proven, not theorised:
#
#     <%# closed with %> like so, see <%= 1 %> and the rest %>
#
# renders " like so, see 1 and the rest %>" into the page while both assertions stay
# green. The fix is one step: signature 2 now STEPS OVER complete ERB tags instead of
# stopping at the first one. Measured before landing, the same way as the other two —
# ZERO candidates across all three enrolled repos at origin/accepted (turf 225 view
# files, hub 214, engine 164), so the widening carries no allowlist and no exemption.
#
# WHAT IT STILL DOES NOT CATCH, stated because a guard that overstates its reach is
# worse than a narrow one: a comment whose tail carries NO second close sequence at
# all — `<%# a note %> and then some prose` with no `%>` after it. That prose really
# does render, but it is textually indistinguishable from the ordinary markup that
# follows almost every comment in the tree, which is the measurement that killed the
# broad widening twice. Catching it needs an allowlist, and an allowlisted guard is
# how a rule stops guarding.
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

  # SIGNATURE 2, WIDENED. Walk forward from a comment's real close, STEPPING OVER
  # complete ERB tags, and report the first close sequence that has no open of its
  # own. That orphan is the author's second `%>` — the tell that one comment became
  # two. Legitimate trailing markup never carries one.
  #
  # THE STEP-OVER IS THE WHOLE FIX. The first version stopped at the next ERB open
  # and only searched the text before it, which a THIRD leak shape walks straight
  # through: when the leaked tail itself REOPENS ERB before the author's second
  # close, that tag's open arrives first, so the orphan is never reached and both
  # shipped signatures stay green while the prose renders. Proven, not theorised —
  # `<%# closed with %> like so, see <%= 1 %> and the rest %>` renders
  # " like so, see 1 and the rest %>" into the page.
  def orphan_close_after?(rest)
    pos = 0
    loop do
      open_at = rest.index(ERB_OPEN, pos)
      close_at = rest.index(ORPHAN_CLOSE, pos)
      return false if close_at.nil?
      return true if open_at.nil? || close_at < open_at

      # A COMPLETE tag stands between here and any orphan: skip past its own close
      # and keep looking. Stopping here is exactly the third shape's escape route.
      tag_close = rest.index(ORPHAN_CLOSE, open_at + ERB_OPEN.length)
      return false if tag_close.nil?

      pos = tag_close + ORPHAN_CLOSE.length
    end
  end

  def leaking_comments(root = view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        next unless orphan_close_after?(rest)

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

  # Guard the WIDENING, which is the only reason this file changed. The third shape
  # is the one BOTH shipped signatures walked through, so a matcher that quietly
  # narrowed back would read as a clean tree — the exact failure the guard-the-guard
  # tests above exist to prevent, one shape later. All three leak shapes are asserted
  # together on purpose: the widening must catch the new one WITHOUT losing either of
  # the two it inherited, and must leave ordinary views alone without an allowlist.
  test "the scan catches all three leak shapes and leaves ordinary views alone" do
    with_probe_tree do |root|
      found = leaking_comments(root)

      assert_includes found.join, "_leak_reopen.html.erb",
                      "the third shape is the one this widening exists for: the leaked tail " \
                      "reopens ERB, so the author's orphan close is never the first thing after " \
                      "the comment and the narrow scan stopped short of it"
      assert_includes found.join, "_leak_close.html.erb",
                      "the widening must not lose the close-only shape it inherited"
      assert_includes found.join, "_leak_open.html.erb",
                      "a quoted ERB open leaves an orphan too, and this scan must still see it"
      assert_equal 3, found.size,
                   "the widening flagged an ordinary view — an allowlist would be the next step, " \
                   "and an allowlisted guard is how a rule stops guarding. Got: #{found.inspect}"
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
      # SHAPE 3 — the tail REOPENS ERB before the author's second close, so the
      # orphan is not the first thing after the comment and the narrow scan stopped
      # short of it. Rails renders " like so, see 1 and the rest %>" into the page.
      File.write(File.join(dir, "probe/_leak_reopen.html.erb"),
                 "<div>\n  <%# closed with %> like so, see <%= 1 %> and the rest %>\n</div>\n")
      # The two legitimate shapes that must stay quiet even after the widening: a
      # comment followed by a real tag, and a comment followed by several. An
      # allowlisted guard is how a rule stops guarding, so these carry its cost.
      File.write(File.join(dir, "probe/_ok_tag.html.erb"),
                 "<div>\n  <%# describes the next line %>\n  <%= render \"x\" %>\n  <p>done</p>\n</div>\n")
      File.write(File.join(dir, "probe/_ok_many.html.erb"),
                 "<div>\n  <%# note %>\n  <span><%= a %></span>\n  <span><%= b %></span>\n</div>\n")
      yield dir
    end
  end
end

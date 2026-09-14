# frozen_string_literal: true

require "open3"
require_relative "../../app/models/release/changelog"

# UpstreamMisfile — the GIT side of the absolute changelog detector
# (/tasks/detect-upstream-changelog-misfiles).
#
# Release::Changelog owns the RULES and stays pure. This owns the three questions
# only git can answer about one tree, and nothing else:
#
#   1. which versions carry a `v*` tag (what SHIPPED),
#   2. what CHANGELOG.md was at each of those tags (the baseline),
#   3. what it was at the commit that WROTE a given line (where its author filed it),
#   4. whether the tree about to be read is the one the merge actually landed on.
#
# ONE TREE, NO SECOND SIDE. That is the whole difference from the promote guard in
# bin/release.rb, which predicts a merge with `git merge-tree` and is blind by
# construction to an entry that arrived mis-filed upstream — such a line is on BOTH
# sides, so the diff shows nothing.
#
# IT FAILS OPEN, AND SAYS SO. A guard that refuses what it cannot read is right when
# a refusal costs a re-run; this is a DETECTOR whose subject is a false sentence in a
# document, and a missing checkout or an unreadable blame is not a reason to stop a
# reviewer's merge. Every give-up returns a `skipped` sentence that the caller PRINTS,
# so a skip is never silent and never mistaken for a clean run.
#
# THE GIT CALLS ARE INJECTED (`git:`) for the same reason the rules are pure: the
# unit test drives this with a hash and the integration test drives it against a real
# repository, and neither needs a network.
module UpstreamMisfile
  CHANGELOG = "CHANGELOG.md"

  # `notice` — the sentence to print, or nil.
  # `findings` — [{ version:, number:, line: }].
  # `judged` — how many entry lines the detector actually looked at. A detector for a
  #   hazard this quiet is worth having only if this number is real, so it travels
  #   with the verdict instead of being inferred from the silence.
  # `skipped` — why nothing was judged, or nil.
  Result = Struct.new(:notice, :findings, :judged, :skipped, keyword_init: true) do
    def found? = !Array(findings).empty?
    def skipped? = !skipped.nil?
  end

  module_function

  def default_git
    lambda do |args|
      out, _err, status = Open3.capture3("git", *args)
      [out, !status.nil? && status.success?]
    end
  rescue StandardError
    ->(_args) { ["", false] }
  end

  # Refresh `path`'s copy of `remote`/`branch` and PROVE the tree `audit` is about to
  # read actually carries the merge. Returns nil when the tree is proven fresh, or a
  # skip Result when it cannot be — which the caller PRINTS, exactly like every other
  # give-up here (/tasks/audit-certifies-a-stale-tree).
  #
  # WHY A STALE TREE IS WORSE THAN AN UNREADABLE ONE. A stale `origin/<branch>` still
  # RESOLVES, so `audit` never reaches a skip branch at all: it reads the PRE-merge
  # tree, finds nothing, and returns a clean verdict carrying a real, non-zero
  # `judged`. That count is this detector's credibility device — it exists so that
  # "zero found" reads as a measurement rather than a vacuum — so a stale tree does
  # not merely lose the finding, it certifies the WRONG TREE with a number. Measured
  # on the shipped path: a failed fetch gave `skipped=nil found=false judged=1` while
  # the real post-merge tree gave `found=true judged=2`.
  #
  # TWO CHECKS, AND EACH CATCHES WHAT THE OTHER CANNOT (measured, real git):
  #
  #   1. THE FETCH'S EXIT STATUS — the mechanism. Catches the refresh that never
  #      landed: a dead token, an unreachable remote, no network (exit 128). It also
  #      catches the PARTIAL refresh that check 2 is structurally blind to: a
  #      force-moved tag is refused (exit 1) while the branch updates anyway, leaving
  #      the branch correct and the local v* tags behind. The tags are this detector's
  #      baseline for what SHIPPED, so stale tags are a wrong verdict — and the
  #      ancestor test passes happily, because the branch really did move.
  #   2. THE MERGE IS AN ANCESTOR — the property. Catches a tree that does not carry
  #      the merge even though the fetch exited 0: replication lag, a checkout
  #      resolved to a different fork, a squash that left no such commit. Check 1 can
  #      only ever test the mechanism that usually delivers the property; this tests
  #      the property itself, which is why it is the stronger of the two.
  #
  # A BLANK `merged_head` disables check 2 and leaves check 1 guarding alone. That is
  # deliberate: the defect above needs a FAILED fetch, which check 1 sees, so not
  # knowing the head is no reason to stop judging a tree that refreshed cleanly.
  def refresh_or_skip(path:, branch:, merged_head: nil, remote: "origin", git: default_git)
    run = ->(*args) { git.call(["-C", path.to_s, *args.map(&:to_s)]) }

    _out, fetched = run.call("fetch", remote, branch, "--tags", "--quiet")
    unless fetched
      return skip("could not refresh #{remote}/#{branch} in #{path}, so the tree here may pre-date the merge " \
                  "and its v* tags may pre-date the release — nothing read from it would be about #{branch}")
    end

    head = merged_head.to_s.strip
    return nil if head.empty?

    _out, carried = run.call("merge-base", "--is-ancestor", head, "#{remote}/#{branch}")
    return nil if carried

    skip("#{remote}/#{branch} in #{path} does not carry the merged head #{head[0, 7]} — the refresh reported " \
         "success, but the tree readable here is not the one the merge landed on")
  rescue StandardError => e
    skip("the freshness check raised #{e.class} (#{e.message}) — the tree could not be proven fresh")
  end

  # Audit ONE checkout at ONE revision.
  def audit(path:, rev:, file: CHANGELOG, git: default_git)
    run = ->(*args) { git.call(["-C", path.to_s, *args.map(&:to_s)]) }

    text, tracked = run.call("show", "#{rev}:#{file}")
    return skip("#{rev} tracks no #{file} — nothing to judge") unless tracked

    tags, tags_ok = run.call("tag", "--list", "v*")
    return skip("could not list #{path}'s v* tags, so 'shipped' has no definition here") unless tags_ok

    published = tags.to_s.lines.map { |tag| tag.strip.delete_prefix("v") }.reject(&:empty?)
    return skip("#{path} carries no v* tag — nothing has shipped, so nothing can be mis-filed") if published.empty?

    blame, blame_ok = run.call("blame", "-l", "--line-porcelain", rev.to_s, "--", file)
    return skip("git blame could not read #{file} at #{rev}, so no line's author can be read") unless blame_ok

    authors = blame_lines(blame)
    tagged = {}
    at_tag = lambda do |version|
      tagged.fetch(version) do
        out, ok = run.call("show", "v#{version}:#{file}")
        tagged[version] = ok ? out : nil
      end
    end
    written = {}
    origin = lambda do |number|
      sha = authors[number - 1]
      next nil unless sha

      written.fetch(sha) do
        out, ok = run.call("show", "#{sha}:#{file}")
        written[sha] = ok ? out : nil
      end
    end

    judged = Release::Changelog.upstream_judged_entries(text, published: published, at_tag: at_tag).size
    found = Release::Changelog.upstream_misfiled_entries(text, published: published, at_tag: at_tag, origin: origin)
    Result.new(notice: Release::Changelog.upstream_misfile_notice(found), findings: found, judged: judged)
  rescue StandardError => e
    skip("the detector raised #{e.class} (#{e.message}) — it judged nothing")
  end

  # line number → the 40-hex sha that last wrote it. A porcelain header is
  # `<sha> <orig-line> <final-line> [<count>]`; every content line is TAB-prefixed,
  # so a `## ` heading in the file can never be read as a header.
  def blame_lines(out)
    lines = []
    out.to_s.each_line do |line|
      match = /\A(\h{40})\s+\d+\s+(\d+)/.match(line)
      next unless match

      lines[match[2].to_i - 1] = match[1]
    end
    lines
  end

  def skip(reason) = Result.new(notice: nil, findings: [], judged: 0, skipped: reason)
end

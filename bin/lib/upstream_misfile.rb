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
#   3. what it was at the commit that WROTE a given line (where its author filed it).
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

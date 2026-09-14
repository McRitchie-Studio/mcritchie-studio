# frozen_string_literal: true

require "test_helper"

# GUARD (sweep-remaining-roll-destination-claims, 2026-09-14): the rung the gem
# version commit lands on is ENFORCED in exactly one place — the push inside
# `commit_gem_version!` — and DOCUMENTED in seven. When
# /tasks/carry-release-commit-onto-accepted moved that push from `release` to
# `accepted`, six of those seven sentences kept asserting the old rung and CI
# stayed green over every one, because each is a COMMENT. Nothing executes a
# comment. This guard closes that hole: it derives the rung from the CODE and asks
# each documenting sentence to agree.
#
# THE GOVERNING RULE THIS ENCODES, and why the last test is the opposite shape of
# the first: a PRESENT-TENSE sentence describing what the pipeline does now must
# move with the behaviour; a PAST-TENSE sentence recording what was MEASURED on a
# date must NOT. A find-and-replace cannot tell those apart — round two of that PR
# rewrote the dated 0.74.4 incident in deployment.md, and round three had to
# restore it. So the present-tense sites are pinned to the DERIVED rung, and the
# dated record is pinned to the rung it actually happened on. A future rung change
# that sweeps both reddens here instead of silently falsifying the record.
#
# WHY CLAIM PHRASES AND NOT RUNG TOKENS. Two of these seams legitimately name BOTH
# rungs — allocation reads `current` from `accepted` while its tag baseline stays
# on `release` — so "this window must not mention release" would false-fail. Each
# site therefore pins the CLAIM, with the rung interpolated, and the same claim
# carrying the opposite rung is what fails it.
#
# Every scan asserts a FLOOR before it grades, so a selector that stops matching
# fails loudly instead of passing over an empty set.
class GemVersionRungDocsTest < ActiveSupport::TestCase
  RELEASE_RB = Rails.root.join("bin/release.rb")

  # ── THE CODE THIS GRADES AGAINST ─────────────────────────────────────────────

  # The body of `commit_gem_version!`, from its def to the next top-level def.
  def commit_gem_version_body
    text  = RELEASE_RB.read
    start = text.index(/^def commit_gem_version!/)
    assert start, "bin/release.rb lost `def commit_gem_version!` — the seam this guard derives the rung from"

    finish = text.index(/^def /, start + 1)
    assert finish, "could not find the def that closes commit_gem_version!"

    body = text[start...finish]
    assert_operator body.length, :>, 500, "the commit_gem_version! slice is implausibly short — a marker moved"
    body
  end

  # The rung that function actually pushes to, resolved THROUGH the branch constant
  # rather than by matching a branch name, so renaming the constant cannot slip past.
  def derived_rung
    consts = commit_gem_version_body.scan(%r{HEAD:refs/heads/\#\{(\w+)\}}).flatten
    assert_equal 1, consts.uniq.size,
      "commit_gem_version! must push to exactly ONE branch constant — found #{consts.inspect}"

    const = consts.first
    value = RELEASE_RB.read[/^#{const} = "([a-z]+)"/, 1]
    assert value, "could not resolve #{const} to a string literal in bin/release.rb"
    value
  end

  def other_rung(rung)
    rung == "accepted" ? "release" : "accepted"
  end

  # Comment markers and hard wrapping are noise here: every claim below wraps
  # across lines, so compare on collapsed, un-commented text.
  def normalize(lines)
    lines.map { |l| l.sub(/^\s*#\s?/, "").strip }.join(" ").gsub(/\s+/, " ")
  end

  def window_at(relative_path, anchor, span)
    path  = Rails.root.join(relative_path)
    lines = path.read.lines
    index = lines.index { |l| l.include?(anchor) }
    assert index, "#{relative_path} lost the anchor #{anchor.inspect} — the seam moved without this guard moving"

    normalize(lines[index, span])
  end

  # ── THE PRESENT-TENSE SITES ──────────────────────────────────────────────────
  #
  # file / anchor / the claim, with the rung interpolated / how many lines it wraps
  # over / why the site matters if it goes stale.
  SITES = [
    { file: "bin/dor-check", anchor: "ALLOCATES it at step 4d", span: 4,
      claim: "onto origin/%s in one commit",
      why: "the rationale a builder reads when dor-check REFUSES their version_file edit" },
    { file: "app/models/release/gem_version.rb", anchor: "current       —", span: 2,
      claim: "the version declared at origin/%s",
      why: "the documented contract of Release::GemVersion.allocation's `current` argument" },
    { file: "app/models/release/gem_version.rb", anchor: "STILL PURE:", span: 4,
      claim: "the version at origin/%s",
      why: "what the allocation's caller is documented to read" },
    { file: "app/models/release/changelog.rb", anchor: "The rolled", span: 4,
      claim: "onto origin/%s BEFORE `gem push`",
      why: "the standing mechanism that makes a mis-filed changelog reach a published artifact" }
  ].freeze

  test "[static] every present-tense site names the rung commit_gem_version! actually pushes to" do
    rung  = derived_rung
    other = other_rung(rung)
    assert_operator SITES.size, :>=, 4, "the site registry emptied out"

    # Grade EVERY site before failing: these went stale as a set, and a report that
    # names one at a time turns one sweep into four round trips.
    stale_sites = SITES.filter_map do |site|
      text    = window_at(site[:file], site[:anchor], site[:span])
      correct = format(site[:claim], rung)
      stale   = format(site[:claim], other)

      next if text.include?(correct) && !text.include?(stale)

      "#{site[:file]} (at #{site[:anchor].inspect}) — expected #{correct.inspect}, " \
        "#{text.include?(stale) ? "still says #{stale.inspect}" : 'says neither'}. It is #{site[:why]}"
    end

    assert_empty stale_sites,
      "commit_gem_version! pushes the version commit to `#{rung}`, but these sentences disagree:\n  " +
      stale_sites.join("\n  ")
  end

  # ── THE UNIQUENESS CLAIM ─────────────────────────────────────────────────────
  #
  # Three sentences argued the producer lock bump's destination by asserting that
  # `bin/release` writes `accepted` NOWHERE else. The version commit made that
  # false. Derive the count from the code rather than trusting any of them.
  FILES_THAT_ARGUED_UNIQUENESS = [
    "bin/release.rb",
    "test/lib/release_producer_lock_bump_test.rb",
    "docs/agents/modules/deployment.md"
  ].freeze

  STALE_UNIQUENESS = [
    /never\s+(?:#\s*)?(?:otherwise\s+)?writes\s+`?accepted`?/im,
    /writes\s+`?accepted`?\s+NOWHERE\s+else/im
  ].freeze

  # Real pushes only: the file also QUOTES `git push origin <sha>:refs/heads/accepted`
  # in prose, and a comment is not a writer.
  def accepted_writer_lines
    RELEASE_RB.read.lines.each_with_index.filter_map do |line, i|
      next if line.strip.start_with?("#")
      next unless line.include?("push") && line =~ %r{refs/heads/(?:\#\{ACCEPTED_BRANCH\}|accepted)}

      "bin/release.rb:#{i + 1}"
    end
  end

  # Report WHERE, never the whole file: these subjects are thousands of lines, and
  # a failure that dumps one is unreadable exactly when it is needed.
  def stale_uniqueness_hits(relative_path)
    lines = Rails.root.join(relative_path).read.lines

    lines.each_with_index.filter_map do |_, i|
      window = normalize(lines[i, 3])
      next unless STALE_UNIQUENESS.any? { |pattern| window.match?(pattern) }

      "#{relative_path}:#{i + 1} — #{window[0, 120]}"
    end
  end

  test "[static] no file claims bin/release writes accepted nowhere else" do
    writers = accepted_writer_lines
    assert_operator writers.size, :>=, 2,
      "expected bin/release.rb to push `accepted` from more than one seam (the version commit and the producer " \
      "lock bump); found #{writers.inspect}. If that is genuinely down to one, the uniqueness claim is true " \
      "again and this test is what should change"

    hits = FILES_THAT_ARGUED_UNIQUENESS.flat_map { |path| stale_uniqueness_hits(path) }
    assert_empty hits,
      "these sentences still assert `bin/release` writes `accepted` nowhere else, but it writes it from " \
      "#{writers.size} seams (#{writers.join(', ')}) — commit_gem_version! is one of them:\n  " +
      hits.join("\n  ")
  end

  # ── THE COUNTER-EXAMPLE: a DATED record must NOT move ─────────────────────────
  #
  # deployment.md's 0.74.4 incident is past tense throughout ("returned", "read",
  # "injected", "filed"), and the rung attaches to `filed`. On 2026-09-09 that
  # commit really did land on `origin/release`. Rewriting it would falsify a
  # measurement — which is precisely what a rung-wide find-and-replace does.
  test "[static] the dated 0.74.4 incident record keeps the rung it actually happened on" do
    text = window_at("docs/agents/modules/deployment.md", "Measured against published 0.74.4", 6)

    assert_includes text, "already shipped",
      "the 0.74.4 incident lost its past-tense body — check this record was not rewritten as live mechanism"
    assert_includes text, "onto `origin/release`",
      "the dated 0.74.4 incident must keep `origin/release`: it records where that commit ACTUALLY landed on " \
      "2026-09-09, not where the pipeline writes today. A present-tense sweep must not touch it"
  end
end

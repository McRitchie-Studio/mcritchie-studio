# frozen_string_literal: true

require "rubygems"

class Release
  # Changelog — THE RELEASE OWNS THE HEADING.
  #
  # `bin/release prepare` allocates a gem's version, writes `version_file` and
  # `Gemfile.lock`, publishes to RubyGems and tags the repo. Until this module it
  # never touched CHANGELOG.md, and nothing anywhere failed when it didn't. So
  # every publish left that release's entries filed under `## Unreleased`, and the
  # heading kept calling shipped history pending.
  #
  # MEASURED 2026-09-09, at origin/release in each repo:
  #
  #   studio-engine   VERSION 0.74.4, newest heading 0.39.0 — 35 minor versions,
  #                   2,382 lines, filed as pending.
  #   solana-studio   VERSION 0.9.1,  newest heading v0.5.0 —  4 minor versions.
  #                   Smaller, same shape, same cause: one shared publisher.
  #   turf-vault      Cargo 0.25.0,   newest heading [0.25.0] — NO drift, and the
  #                   reason is the control: it is registered under `apps`, not
  #                   `gems` (no gemspec, nothing on RubyGems), so prepare never
  #                   writes its version and a human rolls the block by hand in
  #                   the same PR that bumps Cargo.toml. The defect is exactly
  #                   co-extensive with the automated path.
  #
  # THE DESIGN CHOICE, and it was a real fork. Prepare could either (a) ROLL the
  # block automatically at publish, or (b) REFUSE to publish while `Unreleased`
  # holds entries and hand the conductor a roll command. This module implements
  # (a) with a fail-closed exception, for three reasons:
  #
  #   1. THE ROLL WRITES NO PROSE. Every bullet under `## Unreleased` was written
  #      by a builder and merged through G2 review. The roll MOVES them; the only
  #      new text is the heading, which is machine data (the version the release
  #      itself just allocated, and the date it published). Prepare already writes
  #      the version literal, the whole `bundle lock` resolution and the commit
  #      message with nobody reading them first.
  #   2. (b) IS CIRCULAR. The version is a property of the RELEASE, derived from
  #      the candidate's membership at sweep time (Release::GemVersion), and
  #      `bin/dor-check` REFUSES a PR that edits the registered version_file. A
  #      conductor asked to hand-roll must therefore write a heading naming a
  #      number that does not exist yet and that no PR is allowed to write —
  #      run prepare, read the refusal, edit a doc, land it on `accepted`, wait
  #      for the batch promote to `release`, re-run — with a multi-repo QA sweep
  #      held on a prose edit the whole time.
  #   3. THE ROLL IS REVERSIBLE AND LANDS BEFORE THE IRREVERSIBLE ACT. It rides
  #      the same commit as version_file + Gemfile.lock, pushed onto
  #      origin/release in phase 0b — BEFORE any `gem push`. So the published
  #      artifact and its tag carry a changelog that already names the version,
  #      and the worst failure is "revert a commit", never "un-push a gem".
  #
  # AND THE EXCEPTION, which is where (b) is right: `refusal` REFUSES when the
  # roll would LIE. A file already carrying a backlog cannot be rolled honestly —
  # stamping thirty-five releases of entries with one new version is a bigger
  # false statement than the one it replaces. So: roll when the roll is true,
  # refuse when it would not be, and never publish unguarded.
  #
  # DELIBERATELY PURE: no git, no filesystem, no network. Every rule here is
  # unit-testable, which matters because the output feeds a commit that precedes
  # an irreversible push.
  module Changelog
    # The standing bucket, in both spellings the ecosystem's files use:
    # `## Unreleased` (studio-engine, solana-studio) and `## [Unreleased]`
    # (turf-vault). Anchored at both ends on purpose — turf-vault carries a
    # historical `## [Unreleased] - 2026-05-18 (post-v0.11.0)` mid-file, and a
    # prefix match would silently treat that frozen heading as a second live
    # bucket.
    UNRELEASED = /\A\#\#[ \t]+\[?Unreleased\]?[ \t]*\z/i

    # Any level-2 heading. The section boundary the roll cuts on.
    HEADING = /\A\#\#[ \t]+/

    # A version heading, in EVERY dialect measured across the three repos:
    #   ## 0.39.0 — 2026-08-11     studio-engine (modern)
    #   ## v0.4.7 (2026-06-05)     solana-studio, and studio-engine's legacy run
    #   ## [0.25.0] - 2026-06-10   turf-vault
    VERSION_HEADING = /\A\#\#[ \t]+(\[?)(v?)(\d+)\.(\d+)\.(\d+)\]?/

    # The date suffixes those dialects attach, tried in order against whatever
    # follows the version token.
    DATE_FORMS = {
      em_dash: /\A[ \t]*—[ \t]*\d{4}-\d{2}-\d{2}/,
      hyphen: /\A[ \t]*-[ \t]*\d{4}-\d{2}-\d{2}/,
      parens: /\A[ \t]*\(\d{4}-\d{2}-\d{2}\)/
    }.freeze

    # How far the newest heading may sit behind the last PUBLISHED version before
    # the file counts as carrying a backlog rather than a gap.
    #
    # NOT ZERO, and the reason is measured: a release that ships no entry at all
    # is legitimate (studio-engine 0.74.4 was one of thirty-four such). Two is the
    # same tolerance studio-engine's own test/lib/changelog_structure_test.rb
    # carries, deliberately, so the runtime guard and the repo guard can never
    # disagree about what counts as drift. Once the roll below is live the
    # expected drift is 0 — this tolerance only grandfathers a hand-bump.
    MAX_MINOR_DRIFT = 2

    module_function

    # --- reading -------------------------------------------------------------

    # Every `## ` heading, in file order, as { number:, line:, version: }.
    # `version` is [major, minor, patch] for a version heading and nil otherwise
    # (including the Unreleased bucket).
    def headings(text)
      text.to_s.lines.each_with_index.filter_map do |line, i|
        stripped = line.chomp
        next unless HEADING.match?(stripped)

        { number: i + 1, line: stripped, version: version_of(stripped) }
      end
    end

    # [major, minor, patch] for a version heading, else nil.
    def version_of(line)
      match = VERSION_HEADING.match(line.to_s)
      match && [match[3].to_i, match[4].to_i, match[5].to_i]
    end

    # The version headings alone, newest-first as the file orders them.
    def versions(text)
      headings(text).select { |h| h[:version] }
    end

    # The lines under `## Unreleased`, with surrounding blank lines removed. `[]`
    # when the bucket is empty or the heading is absent — the caller cannot tell
    # those apart from here, and does not need to: both mean "nothing to move".
    def unreleased_entries(text)
      lines = body_lines(text)
      start = unreleased_index(lines)
      return [] unless start

      trim(lines[(start + 1)...section_end(lines, start)])
    end

    def entries?(text)
      !unreleased_entries(text).empty?
    end

    # --- the dialect ---------------------------------------------------------

    # How THIS file writes a version heading, derived from what it already
    # contains rather than imposed. Reproducing the file's own dialect is not
    # cosmetic: a second dialect in one file breaks that repo's own structure
    # test and every reader's regex, which is the failure this module exists to
    # make impossible.
    #
    #   bracketed / v_prefix — from the NEWEST version heading (the live form).
    #   date                 — from the newest version heading that CARRIES a
    #                          date; solana-studio's newest heading (`## v0.5.0`)
    #                          has none while its neighbours do, so reading the
    #                          date form off the newest alone would drop the date
    #                          from every future heading in that repo.
    #
    # With no version heading at all there is no dialect to copy, so it falls back
    # to studio-engine's modern form — the ecosystem's canonical shape, and the
    # only one a brand-new gem's first heading can be judged against.
    def dialect(text)
      parsed = versions(text)
      newest = parsed.first
      match  = newest && VERSION_HEADING.match(newest[:line])

      {
        bracketed: match ? !match[1].empty? : false,
        v_prefix: match ? !match[2].empty? : false,
        date: parsed.filter_map { |h| date_form(h[:line]) }.first || (newest ? :none : :em_dash)
      }
    end

    # The date form one heading uses, or nil when it carries no date.
    def date_form(line)
      match = VERSION_HEADING.match(line.to_s)
      return nil unless match

      tail = line.to_s[match.end(0)..].to_s
      DATE_FORMS.each { |name, pattern| return name if pattern.match?(tail) }
      nil
    end

    # The heading this file would write for `version` on `date`.
    def heading_for(version, date, dialect)
      token = "#{dialect[:v_prefix] ? 'v' : ''}#{version}"
      token = "[#{token}]" if dialect[:bracketed]

      case dialect[:date]
      when :em_dash then "## #{token} — #{date}"
      when :hyphen  then "## #{token} - #{date}"
      when :parens  then "## #{token} (#{date})"
      else "## #{token}"
      end
    end

    # --- the guard -----------------------------------------------------------

    # A sentence naming why this file must NOT be rolled, or nil when it is safe.
    #
    # `published_version` is the last version actually released ("0.74.4"), or nil
    # when nothing has shipped yet.
    #
    # THE PARSE FLOOR IS DERIVED, NEVER A CONSTANT — and that is the whole point.
    # studio-engine's own guard carries MIN_VERSION_HEADINGS = 110 against a real
    # 115; carried into a repo with eleven headings that floor can never fire, and
    # the guard passes VACUOUSLY, which is precisely the failure the floor was
    # added to catch. So the floor here is a PROPERTY, not a count: EVERY `## `
    # heading below the bucket must parse as a version. If the regex ever stops
    # matching a repo's dialect, every heading in that repo becomes unparseable at
    # once and this refuses loudly — the parsed set can never quietly collapse to
    # zero, and there is no number to copy wrong.
    def refusal(text, published_version: nil)
      lines = body_lines(text)
      all   = headings(text)

      return "CHANGELOG.md has no '## ' headings at all — refusing to guess where a version heading belongs" if all.empty?

      buckets = all.select { |h| UNRELEASED.match?(h[:line]) }
      if buckets.size != 1 || buckets.first[:number] != all.first[:number]
        return unreleased_refusal(all, buckets)
      end

      unparsed = all.reject { |h| h[:version] || UNRELEASED.match?(h[:line]) }
      if unparsed.any?
        named = unparsed.first(3).map { |h| "line #{h[:number]}: #{h[:line].inspect}" }.join("; ")
        return "CHANGELOG.md has #{unparsed.size} '## ' heading(s) that parse as neither a version nor the " \
               "Unreleased bucket (#{named}) — the parser and the file disagree, and rolling into a file this " \
               "cannot read would put the new heading in the wrong place"
      end

      newest = versions(text).first
      published = parse_version(published_version)
      return nil unless published # nothing shipped yet — no floor to judge against

      unless newest
        return "CHANGELOG.md names no version at all, but #{published_version} is already published — the file " \
               "is not a record of this gem's releases and must not be rolled into blindly"
      end

      ahead_or_backlog(newest[:version], published, published_version, entries?(text))
    end

    def unreleased_refusal(all, buckets)
      return "CHANGELOG.md has no '## Unreleased' heading — there is no bucket to roll" if buckets.empty?

      if buckets.size > 1
        return "CHANGELOG.md has #{buckets.size} '## Unreleased' headings (lines " \
               "#{buckets.map { |h| h[:number] }.join(', ')}) — refusing to guess which one is live"
      end

      "CHANGELOG.md's '## Unreleased' heading is not the first '## ' heading (#{all.first[:line].inspect} sits " \
        "above it at line #{all.first[:number]}) — refusing to roll into a file whose bucket has moved"
    end

    # AHEAD is documented-before-shipped; BACKLOG is the defect this module
    # exists for. A backlog only refuses when the bucket actually HOLDS entries:
    # with an empty bucket the roll writes a heading and moves nothing, so there
    # is no history to mis-file and no reason to hold the sweep.
    def ahead_or_backlog(newest, published, published_label, holds_entries)
      if (newest <=> published) > 0
        return "CHANGELOG.md's newest heading (#{newest.join('.')}) is AHEAD of the last published version " \
               "(#{published_label}) — a version was documented before it shipped"
      end

      return nil unless holds_entries

      major_gap = published[0] - newest[0]
      drift     = major_gap.zero? ? published[1] - newest[1] : nil
      return nil if drift && drift <= MAX_MINOR_DRIFT

      behind = drift ? "#{drift} minor version(s)" : "a whole major version"
      "CHANGELOG.md carries a BACKLOG: the newest heading is #{newest.join('.')} but #{published_label} is " \
        "already published — #{behind} of shipped entries are still filed under '## Unreleased'. Rolling them " \
        "under one new heading would file that whole history as a single release, so this refuses instead. " \
        "Attribute them to their real versions first (studio-engine's docs/RELEASE.md, 'Rolling Unreleased " \
        "into a version'), land that on the gem's `accepted`, then re-run `bin/release prepare` — it resumes, " \
        "and NOTHING has been published"
    end

    # --- the roll ------------------------------------------------------------

    # `text` with the `## Unreleased` block moved under a new version heading, or
    # nil when there is no bucket to roll (the caller has already run `refusal`).
    #
    # THE BUCKET STAYS. `## Unreleased` remains the first heading, now empty and
    # ready for the next cycle; the new version heading goes directly beneath it
    # with the entries under that.
    #
    # THE HEADING IS WRITTEN EVEN WHEN THE BUCKET IS EMPTY, and that is a choice
    # rather than an oversight. It keeps ONE invariant exact — the newest heading
    # names the newest published version, always — which is what makes the drift
    # guard above a measurement instead of an estimate. It also makes the second,
    # independent gap VISIBLE: thirty-four studio-engine releases documented
    # nothing, and under this rule each of them shows as a heading with no entries
    # instead of vanishing into a silent gap in the numbering.
    def roll(text, version:, date:)
      lines = body_lines(text)
      start = unreleased_index(lines)
      return nil unless start

      finish  = section_end(lines, start)
      body    = trim(lines[(start + 1)...finish])
      heading = heading_for(version, date, dialect(text))

      rolled = lines[0..start] + [""] + [heading]
      rolled += [""] + body unless body.empty?
      rolled += [""] + lines[finish..]

      "#{rolled.join("\n").rstrip}\n"
    end

    # --- internals -----------------------------------------------------------

    def body_lines(text)
      text.to_s.lines.map(&:chomp)
    end

    def unreleased_index(lines)
      lines.index { |line| UNRELEASED.match?(line) }
    end

    # The line index where the section opened at `start` ends — the next `## `
    # heading, or end of file.
    def section_end(lines, start)
      ((start + 1)...lines.size).find { |i| HEADING.match?(lines[i]) } || lines.size
    end

    def trim(slice)
      Array(slice).drop_while { |line| line.strip.empty? }.reverse.drop_while { |line| line.strip.empty? }.reverse
    end

    def parse_version(raw)
      text = raw.to_s.strip.sub(/\Av/, "")
      return nil unless /\A\d+\.\d+\.\d+\z/.match?(text)

      text.split(".").map(&:to_i)
    end
  end
end

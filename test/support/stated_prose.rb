# frozen_string_literal: true

# StatedProse — every place this repo STATES something a reader may act on.
#
# WHY THIS EXISTS. A `test/docs` guard that globs a DIRECTORY cannot see a site
# making the very claim it polices from OUTSIDE that directory. The reviewer-select
# preview guard (review_lane_docs_test) globbed docs/agents/**/*.md and missed the
# bare invocation in app/services/reviewer_selector.rb, the feature's OWN service.
# Prose is not a directory.
#
# WHY ONE MODULE AND NOT WIDER GLOBS. Widening a guard's glob changes the population
# every future author is measured against. Two builders answering that separately
# produce two globs and two exemption conventions. So the population is decided ONCE,
# here, and every guard over stated prose reads it.
#
# COMMENTS ONLY, OUTSIDE MARKDOWN — and the omission is measured, not assumed. In a
# non-markdown file this module blanks every line that is not a comment (see #prose).
# Scanning code bodies is where false positives come from: identifiers, string
# literals and the guards' own regexes all read as prose to a text matcher. Both live
# defects above are in comments, and the non-comment candidates in the same files were
# checked and are not defects — `bin/reviewer-select`'s OptionParser banner and its
# `die!` usage string both LIST `--no-record` as an option rather than instructing a
# preview. A reader reads `--help`, not the source that prints it.
#
# LINE NUMBERS SURVIVE, because a blanked line is replaced by an EMPTY line rather
# than dropped. So an offender still cites the line a reader can open, and a comment
# block separates into paragraphs on its own: a lone `#` and a run of code both become
# blank lines, which is exactly the blank-line paragraph break the markdown guards
# already use.
require "pathname"

module StatedProse
  module_function

  # Where prose lives. Markdown ANYWHERE — the root README/RUNBOOK state operating
  # facts too, and `docs/**` was never the whole of it — plus the comment bodies of
  # the surfaces where this house DECLARES things: the registries under `config/`,
  # the models and services that implement them, the shared lib, and the `bin/`
  # scripts agents actually run.
  GLOBS = %w[
    **/*.md
    config/**/*.yml
    app/**/*.rb
    lib/**/*.rb
    bin/*
  ].freeze

  # ONE exemption convention, shared by every guard that reads this population.
  #
  # `/.worktrees/` IS LOAD-BEARING AND IS NOT COSMETIC. Every desk is a full checkout
  # nested inside the primary, so a `**/*.md` glob run from a primary checkout would
  # scan every in-flight task's tree and report other people's drafts as this repo's
  # offenders — findings no one could act on and that change between runs. The old
  # `docs/**/*.md` glob never hit this because `.worktrees` is not under `docs/`.
  #
  # `/test/` is excluded because a guard cannot scan its own fixtures: both guards
  # carry verbatim copies of the defective prose they exist to catch, so a population
  # including `test/` reds every guard against itself. That is a real hole — a figure
  # stated in a test comment goes unguarded — and it is the price of the fixtures.
  #
  # `/archive/` CARRIES ITS TRAILING SLASH, which the lane guard's copy lacked. Bare
  # `/archive` also matches `/archived-*` and any path segment merely beginning with
  # those seven letters, silently exempting live files.
  EXCLUDED = %w[
    /.git/
    /.worktrees/
    /node_modules/
    /vendor/
    /tmp/
    /log/
    /coverage/
    /storage/
    /public/
    /test/
    /archive/
    /audits/
  ].freeze

  # A doc that declares itself a snapshot is a record of what was true on its date.
  # Correcting its figures would falsify the record, so it is out of scope.
  #
  # NOT a bare `ARCHIVED`, and that omission is the whole correctness of this
  # carve-out. `archived` is a task STAGE in this house, printed in the lifecycle list
  # near the top of a spec — so matching it exempted FOUR LIVE DOCS, measured at review
  # 2026-09-22: system/devops-cycle-design.md, system/mission.md, system/news-pipeline.md
  # and topics/data-model.md. Both files this carve-out exists for say ARCHIVE-ONLY in
  # as many words, so the explicit banner is enough.
  FROZEN_BANNER = /ARCHIVE-ONLY|HISTORICAL RECORD|POINT-IN-TIME|AUDIT SNAPSHOT/i

  # A line that is nothing but a comment marker, or a comment marker then text.
  # Covers `#` (Ruby, YAML, shell) — the only comment syntax in the globs above.
  #
  # MATCHED AGAINST A CHOMPED LINE, and that is not a detail. With the newline still
  # attached, `(.*)\z` cannot reach the end of the string — `.` does not cross a
  # newline and `\z` is the absolute end — so EVERY line failed to match, every
  # non-markdown file read as blank, and the first probe of this population reported
  # a clean tree because it had scanned nothing at all. A guard that finds nothing
  # looks exactly like a guard that finds no defects.
  COMMENT = /\A[ \t]*#[ \t]?(.*)\z/

  # Every source in the population, absolute, sorted, frozen records dropped.
  def sources(root)
    root = Pathname.new(root)

    GLOBS.flat_map { |glob| Dir.glob(root.join(glob)) }
         .uniq
         .reject { |path| excluded?(root, path) }
         .select { |path| File.file?(path) && text?(path) }
         .reject { |path| frozen_record?(path) }
         .sort
  end

  # Paths this population declines to read at all — separated from #sources so the
  # carve-out test can ask what the FROZEN banner alone exempts, rather than
  # conflating it with the vendored and nested-desk drops.
  def candidates(root)
    root = Pathname.new(root)

    GLOBS.flat_map { |glob| Dir.glob(root.join(glob)) }
         .uniq
         .reject { |path| excluded?(root, path) }
         .select { |path| File.file?(path) && text?(path) }
         .sort
  end

  # A path ESCAPING the root is excluded, and that needs saying explicitly:
  # `relative_path_from` happily answers "../elsewhere/…" for two absolute paths
  # rather than raising, so a rescue alone let anything outside the repo through as
  # this repo's own prose.
  def excluded?(root, path)
    rel = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    return true if rel == ".." || rel.start_with?("../")

    EXCLUDED.any? { |fragment| "/#{rel}".include?(fragment) }
  rescue ArgumentError # no relative path exists at all (different prefixes)
    true
  end

  def frozen_record?(path)
    File.foreach(path).first(10).any? { |line| line.match?(FROZEN_BANNER) }
  rescue ArgumentError, Errno::EISDIR
    false
  end

  # Cheap binary screen: `bin/` holds scripts, but nothing here should read a blob.
  def text?(path)
    head = File.binread(path, 4096).to_s
    !head.include?("\0")
  rescue SystemCallError
    false
  end

  # The file's PROSE, line-for-line. Markdown is prose already. Anything else keeps
  # its comment bodies and blanks every other line, so line numbers still point at
  # something a reader can open and code can never be read as a claim.
  def prose(path)
    text = File.read(path)
    return text if File.extname(path) == ".md"

    text.lines.map { |line|
      match = COMMENT.match(line.chomp)
      match ? "#{match[1].rstrip}\n" : "\n"
    }.join
  end

  # Path as a reader would cite it.
  def rel(root, path)
    path.to_s.sub("#{root}/", "")
  end
end

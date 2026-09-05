# frozen_string_literal: true

require "test_helper"

# GUARD (guard-start-here-labels, 2026-09-04): the "Start Here" table in
# docs/agents/index.md is prose-labelled — `| Turf Monster live score watch SOP |
# `…/sops/live-score-watch.md` |` — and until this test existed NOTHING checked
# that the prose label still names the invocation the row's file actually
# registers.
#
# That gap shipped a real defect. index.md:613 read:
#
#     | Turf Monster QA contest rehearsal SOP | `…/sops/contest-rehearsal.md` |
#
# The act is invoked as `contest-rehearsal`; `qa-contest-rehearsal` is the BIN
# COMMAND. An agent resolving the Start Here row would have gone looking for an
# invocation that is not in the registry. It was caught by a human reading the
# table, and fixed by hand in finish-turf-monster-act-docs — with no guard added,
# which is the identical mechanism that produced heartbeats.md:20.
#
# Neither existing test covers these rows:
#   · sop_registry_docs_test.rb  — its ROW regex requires a THREE-column row with
#     a backticked invocation in column 1, so the two-column Start Here rows are
#     invisible to it. It pins that the PATHS exist and that the two registry
#     tables agree; it never reads a prose label.
#   · doc_owner_prose_guard_test.rb — ACT_OWNER pairs an act with a SOUL. It has
#     no opinion about whether a label spells the act correctly.
#
# ── Why this anchors on the PATH ──────────────────────────────────────────────
#
# The file name IS the invocation (`sops/clean-infra.md` ⇒ `clean-infra`), so the
# expected value is DERIVED from the row rather than restated in a table here.
# That is what keeps this guard from drifting away from the thing it polices — a
# hand-maintained list of expected labels would need its own guard.
#
# Anchoring on the label text instead is what made an earlier scoping look
# expensive ("40 rows, 16 legitimately exempt"). Path-anchored, the corpus is 22
# rows — 17 sops/ rows + 5 HEARTBEAT rows — with THREE exceptions, all Carl's.
#
# ── Why containment is NOT the check ──────────────────────────────────────────
#
# The tempting rule is "the de-hyphenated label CONTAINS the invocation". It is
# itself the bug. Run it against the defect above:
#
#     "Turf Monster QA contest rehearsal SOP" ⇒ turf-monster-qa-contest-rehearsal-sop
#
# That string contains `contest-rehearsal`, hyphen-bounded on both sides
# (`qa-` … `-sop`). A containment guard — even a boundary-anchored one — reports
# the shipped defect as CLEAN. Containment also accepts a PREFIX as a whole
# invocation: `pr-review` sits inside `pr-review-slow`, so a row pointing at
# pr-review-slow.md passes on a label that only ever says "pr review".
#
# So the check is STRUCTURAL and it asserts EQUALITY. House form for these rows is
#
#     <Soul> <invocation> SOP [(parenthetical)]
#
# and both boundaries come from the path: the soul from the `agents/<soul>/`
# segment, the invocation from the basename. Everything between the soul prefix
# and the `SOP` marker must EQUAL the invocation — not contain it, not start with
# it. "QA contest rehearsal" fails because the extracted phrase is
# `qa-contest-rehearsal`, which is not `contest-rehearsal`.
#
# ── Scope boundary, stated rather than assumed ────────────────────────────────
#
# Only rows whose target is `docs/agents/agents/<soul>/sops/<name>.md` or
# `docs/agents/agents/<soul>/HEARTBEAT.md` are guarded. The SHARED invocations
# (`process-backlog`, `work-backlog`, `address-blocker`, `token-session`,
# `knowledge-capture`, `building-sop`) live under `docs/agents/modules/` and are
# deliberately OUT of scope: they carry no soul prefix and no `SOP` suffix, so the
# structural rule above does not describe them. Two of them would need their own
# exceptions ("Address a blocker (shared primitive)" ⇒ `address-a-blocker`;
# "GitHub token session broken (…)" ⇒ no `token-session` at all). Widening to
# modules/ means designing a second rule for that shape — worth doing, but it is
# not this guard, and pretending otherwise would bury two real misses in a
# skip list.
class StartHereLabelGuardTest < ActiveSupport::TestCase
  INDEX = Rails.root.join("docs/agents/index.md")
  SECTION_HEADING = "## Start Here"

  # Two-column Start Here row pointing into an agent's own SOP or heartbeat file.
  # The three-column registry tables cannot match: they carry an Owner column
  # between the label and the path.
  ROW = %r{
    ^\|\s*(?<label>[^|]+?)\s*\|\s*
    `mcritchie-studio/(?<path>docs/agents/agents/(?<soul>[a-z_]+)/
    (?:sops/(?<sop>[a-z0-9-]+)|HEARTBEAT)\.md)`\s*\|\s*$
  }x

  # ── The three exceptions, DECIDED ─────────────────────────────────────────
  #
  # All three are Carl's, and all three fail for the same reason: the label
  # describes the SOP's ROLE ("slow", "primary reviewer", "light reviewer")
  # instead of spelling the invocation, so the phrase between soul and `SOP`
  # reconstructs to something that is not the act name.
  #
  # Carried as a NAMED list rather than relabelled, on this distinction: the
  # defect this guard exists for INVENTED A PLAUSIBLE INVOCATION. "QA contest
  # rehearsal" reads exactly like an act name, and the act name it reads like
  # (`qa-contest-rehearsal`) is a real command — so the row actively misdirects.
  # "Carl primary reviewer role SOP" reads as a DESCRIPTION and could not be
  # mistaken for something to type. Start Here is a Need→Read index; the two
  # registry tables are the invocation index and already carry these three names
  # verbatim in backticks, so nothing is unfindable.
  #
  # That is a judgment call, recorded here so the next reader inherits the
  # reasoning and not just the skip.
  #
  # It is not a free pass: "the exception list is not stale" below re-checks that
  # every entry STILL fails the rule. Relabel one of these correctly and this
  # test fails until its exception is deleted, so the list cannot rot into a
  # place where real drift hides.
  LABEL_EXCEPTIONS = {
    "docs/agents/agents/carl/sops/pr-review-slow.md" =>
      "labelled 'Carl slow PR review SOP' — reads as the slow variant of pr-review, " \
      "which is what the row means; the invocation is pr-review-slow",
    "docs/agents/agents/carl/sops/pr-review-primary.md" =>
      "labelled 'Carl primary reviewer role SOP' — names the ROLE, deliberately; " \
      "the invocation is pr-review-primary",
    "docs/agents/agents/carl/sops/pr-review-light.md" =>
      "labelled 'Carl light reviewer role SOP' — names the ROLE, deliberately; " \
      "the invocation is pr-review-light"
  }.freeze

  # Down to the same alphabet the invocations use, so a label and a file name are
  # comparable at all: "Steffon clean infra SOP (worktrees, disk, "no space")"
  # becomes steffon-clean-infra-sop-worktrees-disk-no-space.
  def slugify(text)
    text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  # `turf_monster` is the directory; `Turf Monster` is the soul, and the label
  # spells it with a space.
  def soul_token(dir)
    dir.tr("_", "-")
  end

  # The Start Here section only. Scoped by heading so a two-column table
  # elsewhere in the file cannot silently join the corpus, and so a renamed
  # heading fails loudly instead of yielding zero rows.
  def start_here_section
    text = INDEX.read
    start = text.index(SECTION_HEADING)
    refute_nil start,
      "docs/agents/index.md lost its '#{SECTION_HEADING}' heading. This guard scopes " \
      "itself by that heading; without it the scan reads NOTHING and passes vacuously."

    finish = text.index(/^## /, start + SECTION_HEADING.length) || text.length
    [ text[start...finish], text[0, start].count("\n") + 1 ]
  end

  def guarded_rows
    section, first_line = start_here_section

    section.lines.each_with_index.filter_map do |line, offset|
      match = ROW.match(line)
      next unless match

      {
        label: match[:label],
        path: match[:path],
        soul: match[:soul],
        sop: match[:sop],
        line: first_line + offset
      }
    end
  end

  # The rule, as a predicate over one row. Returns nil when the label is well
  # formed, or a human sentence naming what it reconstructed to and what the path
  # demanded. Split out so the control below can drive it with text that is NOT
  # in the repo.
  def label_violation(label:, soul:, sop:, **)
    slug = slugify(label)
    prefix = "#{soul_token(soul)}-"

    unless slug.start_with?(prefix)
      return "label #{label.inspect} must begin with the soul the path names " \
             "(#{soul_token(soul)}); it reconstructs to #{slug.inspect}"
    end

    segments = slug.delete_prefix(prefix).split("-")

    # HEARTBEAT rows: the file name is not an invocation, so the invocation is
    # "<Soul> Heartbeat" and the assertion is that the label says so immediately
    # after the soul. This is what catches a copy-pasted row pointing at another
    # soul's HEARTBEAT.md.
    if sop.nil?
      return nil if segments.first == "heartbeat"

      return "label #{label.inspect} points at #{soul_token(soul)}'s HEARTBEAT.md, so it must " \
             "read '#{label.split.first} Heartbeat …' — the invocation is " \
             "`#{soul_token(soul).split('-').map(&:capitalize).join(' ')} Heartbeat`"
    end

    marker = segments.index("sop")
    if marker.nil?
      return "label #{label.inspect} carries no 'SOP' marker, so the invocation phrase has no " \
             "right boundary. House form for these rows is '<Soul> <invocation> SOP'."
    end

    phrase = segments[0...marker].join("-")
    return nil if phrase == sop

    "label #{label.inspect} reconstructs to #{phrase.inspect} between the soul and 'SOP', " \
      "but the path registers the invocation as #{sop.inspect}"
  end

  # ── The corpus ────────────────────────────────────────────────────────────

  test "the Start Here scan actually reaches the rows it claims to guard" do
    rows = guarded_rows

    # A guard that reads nothing passes. Pin the corpus to DISK rather than to a
    # magic number: every SOP and heartbeat file that exists must have been seen
    # by the scan, so adding an SOP without a Start Here row fails here, and the
    # guard cannot quietly shrink to zero.
    on_disk = Dir.glob(Rails.root.join("docs/agents/agents/*/sops/*.md")).map do |path|
      Pathname.new(path).relative_path_from(Rails.root).to_s
    end
    on_disk += Dir.glob(Rails.root.join("docs/agents/agents/*/HEARTBEAT.md")).map do |path|
      Pathname.new(path).relative_path_from(Rails.root).to_s
    end

    seen = rows.map { |row| row[:path] }

    assert_operator rows.length, :>=, 20,
      "the Start Here scan matched only #{rows.length} rows — it has stopped reading the table"
    assert_empty on_disk.sort - seen.sort,
      "These SOP/heartbeat files exist on disk but no Start Here row in docs/agents/index.md " \
      "points at them, so this guard never inspects a label for them. Add the row."
    assert_empty seen.tally.select { |_, count| count > 1 },
      "a Start Here path appears on more than one row; the table should index each file once"
  end

  test "every Start Here SOP row label reconstructs to the invocation its path names" do
    offenders = guarded_rows.filter_map do |row|
      next if LABEL_EXCEPTIONS.key?(row[:path])

      why = label_violation(**row)
      next if why.nil?

      "docs/agents/index.md:#{row[:line]}  — #{why}"
    end

    assert_empty offenders,
      "These Start Here rows label an SOP with something other than the invocation the agent " \
      "must actually type. The file name IS the invocation, so the label has to reconstruct to " \
      "it — an agent resolving the row otherwise goes looking for an act the registry does not " \
      "contain (this is exactly how index.md shipped 'QA contest rehearsal' for " \
      "`contest-rehearsal`).\n#{offenders.join("\n")}"
  end

  test "the exception list is not stale" do
    rows = guarded_rows.index_by { |row| row[:path] }

    LABEL_EXCEPTIONS.each_key do |path|
      row = rows[path]
      assert_not_nil row,
        "#{path} is carried as a Start Here label exception but has no Start Here row. " \
        "Delete the exception."
      assert_not_nil label_violation(**row),
        "#{path} is carried as a Start Here label exception, but its label now satisfies the " \
        "rule. Delete the exception — a skip list that outlives its reason is where real drift hides."
    end
  end

  # ── The control ───────────────────────────────────────────────────────────
  #
  # The deliverable IS a test, so the load-bearing question is whether it BITES.
  # These drive the same predicate the corpus test uses with text the repo does
  # not contain.

  test "the guard flags the qa-contest-rehearsal label that actually shipped" do
    # Verbatim from index.md before finish-turf-monster-act-docs fixed it by hand.
    why = label_violation(
      label: "Turf Monster QA contest rehearsal SOP",
      soul: "turf_monster",
      sop: "contest-rehearsal"
    )

    assert_not_nil why, "the guard must flag the label that shipped the defect this task exists for"
    assert_includes why, "qa-contest-rehearsal"
    assert_includes why, "contest-rehearsal"
  end

  test "the guard accepts the corrected label for the same row" do
    assert_nil label_violation(
      label: "Turf Monster contest rehearsal SOP (QA devnet lifecycle)",
      soul: "turf_monster",
      sop: "contest-rehearsal"
    )
  end

  test "a prefix of a longer invocation is not accepted as the whole invocation" do
    # `pr-review` is a genuine invocation AND a prefix of three others. A
    # containment check passes both of these; equality fails both.
    assert_not_nil label_violation(
      label: "Carl PR review SOP",
      soul: "carl",
      sop: "pr-review-slow"
    ), "a label naming `pr-review` must not satisfy a row registering `pr-review-slow`"

    assert_not_nil label_violation(
      label: "Carl PR review light SOP",
      soul: "carl",
      sop: "pr-review"
    ), "a label naming `pr-review-light` must not satisfy a row registering `pr-review`"
  end

  test "an invocation buried behind extra words is flagged even though it is present" do
    # The whole point: `clean-infra` IS in this label, hyphen-bounded. Containment
    # would pass it; the structural rule does not.
    why = label_violation(
      label: "Steffon emergency clean infra SOP",
      soul: "steffon",
      sop: "clean-infra"
    )

    assert_not_nil why
    assert_includes why, "emergency-clean-infra"
  end

  test "a heartbeat row pointed at the wrong soul is flagged" do
    assert_nil label_violation(label: "Carl heartbeat launcher", soul: "carl", sop: nil)

    assert_not_nil label_violation(label: "Carl heartbeat launcher", soul: "avi", sop: nil),
      "a Start Here row whose label names Carl but whose path is avi/HEARTBEAT.md must be flagged"
  end

  test "a label with no SOP marker is flagged rather than skipped" do
    why = label_violation(
      label: "Steffon clean infra runbook",
      soul: "steffon",
      sop: "clean-infra"
    )

    assert_not_nil why, "a row with no right boundary must fail loudly, not fall through as clean"
    assert_includes why, "SOP"
  end
end

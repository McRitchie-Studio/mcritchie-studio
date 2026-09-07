# frozen_string_literal: true

require "test_helper"

# config/feature_shapes.yml carries a HAND-AUDITED list of which repos actually
# collect an e2e lane, because bin/dor-check credits any `[e2e]` tag a builder
# types and a repo with no playwright job can only ever supply a fabricated one.
#
# The file already told the next person what to do — "DO re-check when a repo is
# added" — and that instruction is exactly what failed. mcritchie-industries
# joined the ecosystem after the 2026-07-14 audit and sat unlisted until a task
# in it demanded a tier it cannot run (2026-08-13,
# /tasks/recover-industries-engine-adoption). An instruction in a comment is not
# a mechanism; this is the mechanism.
#
# SCOPE: staleness only. This does NOT check that the audit's VERDICT is right —
# proving "this repo runs no playwright lane" needs that repo checked out, and NOTHING DOES
# IT. That per-repo tier-collectability work is UNBUILT and unowned; the task this line once
# named was archived without it landing, so naming a task here read as "handled" and was not.
# config/feature_shapes.yml's header states the limitation and the condition that would lift
# it. This asserts something weaker and durable: every app the studio manages has a
# LINE in the audit, so adding an app cannot silently skip the question.
class FeatureShapesAuditTest < ActiveSupport::TestCase
  SHAPES = Rails.root.join("config/feature_shapes.yml")
  # The app registry this repo already keeps. Using an existing source rather
  # than a second hand-maintained list — a guard against staleness that is
  # itself hand-maintained just moves the staleness somewhere quieter.
  REGISTRY = Rails.root.join("config/qa_environments.yml")

  # The audit's BULLET LINES only. Matching the name anywhere in the block is a
  # substring proxy, not the property: the prose above the list mentions the
  # repos too, so deleting a repo's bullet left the guard green. Found by
  # mutation — the first version of this test could not fail.
  BULLET = "\u00B7"

  def audit_block = SHAPES.read[/Audited by hand.*?^# The fix is/m].to_s

  def audit_line_for(app)
    audit_block.lines.find { |line| line.include?(BULLET) && line.include?(app) }
  end

  # "qa_environments", not "apps" — the first version fetched a key that does not
  # exist, so this returned [] and BOTH tests below passed vacuously. A guard
  # that cannot fail is the exact disease this file documents, so the empty case
  # is now an explicit failure rather than a silent pass.
  # The LOOKBEHIND is what fixes this, not the case. /COLLECTED/i let
  # "unCOLLECTED" through because the word sat inside another word; rejecting any
  # letter immediately before it kills "uncollected", "recollected" and
  # "precollected" whatever their case. So `i` stays — a verdict written in lower
  # case is still a verdict, and failing it would be pedantry rather than a
  # guard.
  VERDICT = /(?<![A-Za-z])(NOT )?COLLECTED/i

  def registered_apps
    apps = YAML.load_file(REGISTRY).fetch("qa_environments", {}).keys
    refute_empty apps, "read no apps from #{REGISTRY} — this guard would pass vacuously"
    apps
  end

  test "every managed app has a line in the e2e collectability audit" do
    missing = registered_apps.reject { |app| audit_line_for(app) }

    assert_empty missing,
      "#{missing.join(', ')} is managed by the studio but has no line in the e2e audit in " \
      "config/feature_shapes.yml. A ui+db task there would demand an `e2e` tier that " \
      "nothing may actually run, and bin/dor-check would credit the tag a builder types. " \
      "Add a line stating whether that repo COLLECTS e2e — this is the check the comment " \
      "'DO re-check when a repo is added' could not enforce on its own."
  end

  # A line that names a repo without answering the question reads as audited and
  # is not.
  #
  # Scoped to registered apps deliberately: the libraries line (studio-engine,
  # solana-studio, turf-vault) answers a different question — no shape DEMANDS
  # e2e of them, so there is nothing to collect — and forcing a COLLECTED verdict
  # onto it would be asserting a spelling rather than the property.
  test "every managed app's audit line carries an explicit collected-or-not verdict" do
    # THE WORD, not the substring. /COLLECTED/i matched inside "unCOLLECTED", so a
    # line reading "e2e uncollected, unverified." — which states the OPPOSITE of a
    # verdict, or no verdict at all — satisfied the guard. Proven by mutation, not
    # argued: that exact line passed with 0 failures.
    #
    # A spelling standing in for the property, which is the third time this file's
    # guards have made that mistake (it first matched a repo name anywhere in the
    # block, then read a registry key that did not exist and passed vacuously).
    undecided = registered_apps.reject { |app| audit_line_for(app)&.match?(VERDICT) }

    assert_empty undecided,
      "#{undecided.join(', ')}: an audit line must say whether e2e is COLLECTED or " \
      "NOT COLLECTED. Naming a repo without a verdict reads as audited and is not."
  end

  # THE HOLE THIS TASK EXISTS TO CLOSE, exercised on the regex directly.
  #
  # Neither test above can tell /COLLECTED/i from the corrected pattern, because
  # every line in the real file happens to carry a well-formed verdict — so the
  # bug was invisible to them and stayed invisible through a full review. Carl
  # found it by writing "e2e uncollected, unverified." into a line and watching
  # the suite stay green.
  #
  # A verdict is the WORD. "uncollected" is not a verdict; it is the absence of
  # one wearing the letters of one.
  # ==== A TASK CITATION IS PROVENANCE, NEVER A PROMISE ================================
  # Measured 2026-09-07: this file family carried FIVE live citations of TWO archived
  # tasks, and the two worst were not dead links — they were promises. The header of
  # config/feature_shapes.yml — the file that decides which tiers a shape demands — read
  # "/tasks/<slug>. Until it lands, this header claims only what it can prove." The slug was
  # dor-check-tiers-per-repo, raised 2026-07-14; it was archived and the per-repo check was
  # NEVER BUILT. (The example is written with a placeholder on purpose: spelled in full it
  # would be an undated, deferring citation, and this guard would flag its own comment —
  # which is the rule holding, not a bug in it.) A dead link costs a reader a click. A
  # promise costs the next person their planning: they read a limitation as temporary, and
  # nobody is working on it.
  #
  # WHY THIS GUARD DOES NOT ASK THE BOARD. A guard that hardcoded "these slugs are archived"
  # would be the same disease one level up — a snapshot that rots — and CI cannot reach the
  # board anyway. So the rule is stated as a CONDITION on the prose itself, which is offline,
  # durable, and true whatever any task's state becomes:
  #
  #   1. DATED. Every citation carries a date within one line of itself, which is what makes
  #      it read as history. An undated citation reads as a live pointer, and a live pointer
  #      to a task is a bet that the task will land.
  #   2. NOT DEFERRING. No citation shares a window with language that hands a described
  #      limitation to that task. State the limitation, or land the fix.
  #
  # Rule 1 is the invariant (no vocabulary, so it cannot be talked around); rule 2 is a net
  # for the dated-but-still-deferring sentence rule 1 waves through.
  CITED_FILES = [
    Rails.root.join("config/feature_shapes.yml"),
    Rails.root.join("test/lib/feature_shape_tiers_test.rb"),
    Rails.root.join("test/lib/feature_shapes_audit_test.rb")
  ].freeze

  # `[a-z0-9]` FIRST, so the `/tasks/<slug>` placeholders in DEFERRAL_SAMPLES below are not
  # themselves read as citations. The samples must be able to say the forbidden thing.
  CITATION = %r{/tasks/[a-z0-9][a-z0-9-]*}
  DATED = /\b20\d{2}-\d{2}-\d{2}\b/

  # ONE LINE EITHER SIDE, and that width is load-bearing rather than arbitrary. At ±2 the
  # "(Repair: /tasks/repair-rotted-e2e-specs)" line borrowed the date off the unrelated
  # "REMOVED 2026-07-13" paragraph two lines below and passed while carrying no date of its
  # own — a window wide enough to find someone else's evidence is a window that certifies
  # nothing. Measured, not guessed: at ±2 that site went green; at ±1 it did not.
  WINDOW = 1

  # Every entry here MUST have a sample in DEFERRAL_SAMPLES, asserted below — an alternative
  # that matches no real sentence is decoration that makes the pattern look sounder than it
  # is. (A sibling guard shipped `/\bn't\b/`, which matches no English contraction, while
  # claiming soundness against negation.)
  DEFERRAL_MARKERS = [
    "until it lands", "once it lands", "when it lands", "will land",
    "filed as", "is filed", "tracked as", "deferred to"
  ].freeze
  DEFERRAL = Regexp.union(DEFERRAL_MARKERS.map { |marker| /#{marker}/i })

  # The slug is deliberately `<slug>` — see CITATION above. These sentences must exercise the
  # markers WITHOUT tripping the scanner that reads this very file.
  DEFERRAL_SAMPLES = {
    "until it lands" => "/tasks/<slug>. Until it lands, this header claims only what it can prove.",
    "once it lands" => "Once it lands (/tasks/<slug>) the qualifier can come out.",
    "when it lands" => "When it lands, see /tasks/<slug>, the tier becomes collectable.",
    "will land" => "The per-repo check will land under /tasks/<slug>.",
    "filed as" => "the per-repo tier-collectability work filed as /tasks/<slug>.",
    "is filed" => "The repair is filed at /tasks/<slug>.",
    "tracked as" => "That gap is tracked as /tasks/<slug>.",
    "deferred to" => "The blast radius is deferred to /tasks/<slug>."
  }.freeze

  # Real provenance, taken from this family's own prose. If the net flags these it is
  # unusable: dated history is the thing the rule exists to PERMIT.
  PROVENANCE_CONTROLS = [
    "Hit live on 2026-08-13 by /tasks/recover-industries-engine-adoption, which was reclassified",
    "decay. (Repair: /tasks/repair-rotted-e2e-specs, 2026-07-13.)",
    "THE CONTROL IS NOW EXECUTED FOR THE HALF THAT CAN BE (2026-08-11, /tasks/<slug>)."
  ].freeze

  def citation_windows
    CITED_FILES.flat_map do |path|
      lines = path.read.lines.map(&:chomp)
      lines.each_with_index.filter_map do |line, index|
        next unless line.match?(CITATION)

        first = [ index - WINDOW, 0 ].max
        { where: "#{path.relative_path_from(Rails.root)}:#{index + 1}",
          text: line.strip,
          window: lines[first..(index + WINDOW)].join("\n") }
      end
    end
  end

  # THE ANTI-VACUITY CONTROL. A scan that reads nothing passes everything, and every guard
  # in this file has made that mistake once already (a registry key that did not exist
  # returned [] and two tests passed green). So prove the corpus was actually opened and the
  # citation pattern actually fired on real committed prose, BEFORE trusting either verdict
  # below. There is no early return anywhere in this class: an exit-blind guard reports green
  # by jumping over its own assertions.
  test "the citation scanner reads the real files and finds real citations" do
    CITED_FILES.each do |path|
      assert path.exist?, "#{path} is gone — this guard's entire corpus, silently empty"
      assert_operator path.read.length, :>, 1_000,
                      "#{path} read as near-empty (#{path.read.length} bytes); a scan of nothing passes everything"
    end

    found = citation_windows
    assert_operator found.length, :>=, 5,
                    "found only #{found.length} task citation(s) across #{CITED_FILES.length} files. This family " \
                    "carries several dated ones on purpose; a near-empty result means CITATION no longer matches " \
                    "the way citations are written, so both guards below are passing on an empty list."
    assert_match(/recover-industries-engine-adoption/, found.map { |w| w[:text] }.join("\n"),
                 "the known dated citation of the Industries reclassification is missing from the scan. If it was " \
                 "legitimately removed, re-point this control at another citation that IS in the files — do not " \
                 "delete the control, which is the only proof the scanner reached real content.")
  end

  test "every task citation is dated, so it reads as provenance rather than a live pointer" do
    undated = citation_windows.reject { |w| w[:window].match?(DATED) }

    assert_empty undated.map { |w| "#{w[:where]}  #{w[:text]}" },
                 "an undated task citation reads as a pointer to work in progress, and a task can be ARCHIVED " \
                 "WITHOUT LANDING — which is exactly what happened to the five citations this guard was built " \
                 "for. Two honest fixes, no third: (a) it IS history — add the date it happened, within one line " \
                 "of the citation; or (b) it is NOT history — then say what is true today (the limitation, and " \
                 "the condition that would lift it) instead of naming a task that may never land."
  end

  test "no task citation defers a stated limitation to that task" do
    deferring = citation_windows.select { |w| w[:window].match?(DEFERRAL) }

    assert_empty deferring.map { |w| "#{w[:where]}  #{w[:text]}" },
                 "this prose hands a limitation it just described to a task URL. A task is not a mechanism: " \
                 "the dor-check-tiers-per-repo task (raised 2026-07-14) was archived with the per-repo tier " \
                 "check unbuilt, leaving \"until it lands\" promising a future nobody was working toward. " \
                 "State the limitation as it stands and name the CONDITION that would lift it — ideally the " \
                 "code a reader can check — rather than deferring to a record that can close without the " \
                 "work happening."
  end

  # Proves the net is made of real English, and that it lets provenance through. Both halves
  # matter: a marker matching nothing is decoration, and a marker matching history would make
  # the rule unusable and get the guard deleted.
  test "every deferral marker is exercised by a sample, and none of them flags provenance" do
    assert_equal DEFERRAL_MARKERS.sort, DEFERRAL_SAMPLES.keys.sort,
                 "every alternative in DEFERRAL must have a sample sentence proving it matches real English. " \
                 "An alternative with no sample is how a pattern ships looking sounder than it is."

    DEFERRAL_MARKERS.each do |marker|
      sample = DEFERRAL_SAMPLES.fetch(marker)
      assert_match(/#{marker}/i, sample, "the sample for #{marker.inspect} must exercise THAT alternative")
      assert_match DEFERRAL, sample, "#{marker.inspect} must make the union pattern fire"
      refute_match CITATION, sample,
                   "#{marker.inspect}'s sample must not contain a REAL citation, or this file trips its own scan"
    end

    PROVENANCE_CONTROLS.each do |line|
      refute_match DEFERRAL, line, "#{line.inspect} is dated history and must pass — the rule permits provenance"
      assert_match DATED, line, "#{line.inspect} is the dated control; without a date it proves nothing here"
    end
  end

  # ==== THE HEADER'S BLIND SPOT, PINNED TO THE CODE RATHER THAN TO PROSE ==============
  # config/feature_shapes.yml says its tier guarantee holds IN THIS REPO ONLY, and that the
  # limitation is PERMANENT rather than pending. That sentence is only honest while
  # bin/dor-check really is blind to a task's own repo, and the tell is mechanical: it credits
  # a tier from the tag alone and never requires the bin/lib/ci_test_command.rb seam, which is
  # the only thing here that reads a repo's ci.yml.
  #
  # So this guard fails when the check is BUILT. That is the point — it is the alarm that
  # stops the header from outliving its own truth, in the direction prose always rots
  # (limitation lifted, paragraph not updated). It is not asking anyone to keep dor-check
  # blind. Landing the check is the good outcome; updating the header is the price.
  DOR_CHECK = Rails.root.join("bin/dor-check")
  CI_SEAM_REQUIRE = /^\s*require(?:_relative)?\s+["'][^"']*ci_test_command/

  test "the per-repo tier blind spot is still open, or feature_shapes.yml's header is stale" do
    source = DOR_CHECK.read
    assert_operator source.length, :>, 10_000,
                    "read bin/dor-check as #{source.length} bytes — too small to be the gate; this guard would " \
                    "be asking a question of an empty string"
    assert_match CI_SEAM_REQUIRE, %(require_relative "lib/ci_test_command"),
                 "the pattern cannot recognise the require it is looking for, so its verdict is meaningless"

    refute_match CI_SEAM_REQUIRE, source,
                 "bin/dor-check now requires the ci_test_command seam, so it may finally resolve a TASK'S REPO " \
                 "and read that repo's ci.yml — the per-repo tier-collectability check config/feature_shapes.yml " \
                 "describes as unbuilt. If you built it: rewrite the **IN THIS REPO** paragraph in that header " \
                 "(it currently calls the limitation PERMANENT and says nobody is building it), rewrite the " \
                 "matching note in test/lib/feature_shape_tiers_test.rb, and delete this guard. If you required " \
                 "the seam for something else, narrow this pattern to the call that resolves the repo."
  end

  test "the verdict pattern matches the word, not a substring inside another" do
    %w[COLLECTED collected].each do |verdict|
      assert_match VERDICT, "e2e #{verdict}.", "a plain verdict must be accepted"
    end
    assert_match VERDICT, "e2e NOT COLLECTED.", "the negative verdict is still a verdict"

    [ "e2e uncollected, unverified.", "e2e recollected later.", "e2e precollected." ].each do |line|
      refute_match VERDICT, line,
        "#{line.inspect} states no verdict — matching it is how a line that says the " \
        "OPPOSITE of an answer passed for an answer"
    end
  end
end

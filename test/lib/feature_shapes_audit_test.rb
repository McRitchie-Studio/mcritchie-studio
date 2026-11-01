# frozen_string_literal: true

require "test_helper"

# config/feature_shapes.yml carries a HAND-AUDITED list of which repos collect an e2e lane,
# because bin/dor-check credits any `[e2e]` tag and a repo with no playwright job can only
# supply a fabricated one. A comment's "re-check" failed (2026-08-13,
# /tasks/recover-industries-engine-adoption); this is the mechanism. SCOPE: staleness only.
# It does NOT check the audit's VERDICT: that needs the repo checked out, NOTHING DOES IT,
# and that work is UNBUILT and unowned (the yml's header states the limit). It asserts every
# app the studio manages has a LINE in the audit.
# History: task recover-industries-engine-adoption.
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

  # "qa_environments", not "apps": a key that does not exist returns [] and BOTH tests below
  # pass vacuously, so the empty case is an explicit failure.
  # The LOOKBEHIND is what fixes this, not the case. /COLLECTED/i let "unCOLLECTED" through;
  # rejecting any letter before the word kills "uncollected", "recollected" and "precollected"
  # in any case. `i` stays: a verdict in lower case is still a verdict.
  # History: task detect-engine-migration-content-drift.
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

  # THE HOLE THIS TASK EXISTS TO CLOSE: every real line has a well-formed verdict, so tests
  # above cannot tell /COLLECTED/i from the fix. "uncollected" is not a verdict.
  # ==== A TASK CITATION IS PROVENANCE, NEVER A PROMISE ================================
  # A promise makes a limitation read as temporary. The guard cannot ask the board, so the
  # rule is a CONDITION on the prose. 1. DATED: a date within one line of every citation. 2.
  # NOT DEFERRING: no citation shares a window with language handing a limitation to that
  # task. Rule 1 is the invariant; rule 2 nets the dated-but-deferring.
  # History: task detect-engine-migration-content-drift.
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

# frozen_string_literal: true

require_relative "../../lib/cert_evidence"

# bin/lib/control_replay.rb — the PURE half of the `test-only` shape's EXECUTED
# control (bin/control-check owns the git harness and the run).
#
# THE QUESTION, AND WHY IT HAS NO OBVIOUS ANSWER
#
# `test-only` drops the tier list, because a diff with no behavior in it gives the
# tiers no subject. What replaces them is a control answering "DOES THE CHANGED
# TEST STILL BITE?" — and until now that control was CHECKED FOR STRUCTURE, never
# executed: bin/dor-check confirmed a `[control]` line existed and named a file in
# the diff, which is a DECLARATION. The whole devops cycle this shape was built in
# is about gates that trust declarations, so a structurally-valid control nobody
# ran is precisely the disease, one level down.
#
# "Execute the control" has three plausible readings. Only one of them is TRUE
# often enough to mechanize, and the other two were rejected on evidence:
#
#   1. REPLAY THE PRE-CHANGE TEST AGAINST CURRENT PRODUCTION CODE.  ← CHOSEN
#      Sound because of a property the shape ALREADY proves: `claimable_when:
#      test_only_diff` refuses the shape unless every changed path is provably test
#      content, so PRODUCTION CODE AT THE BASE IS BYTE-IDENTICAL TO PRODUCTION CODE
#      AT HEAD. Restoring only the changed test files to their base content
#      therefore reproduces the parent state exactly for those files — no parent
#      checkout, no hybrid tree. The claimability allowlist is not a nicety here;
#      it is the precondition that makes this replay mean anything.
#
#   2. MUTATE THE CHANGED ASSERTION AND REQUIRE RED. Closest to the literal
#      question, and not generically automatable: it needs to parse Ruby (and JS)
#      to find "the" assertion, know which mutation is meaningful rather than
#      merely syntactic, and it has NO target at all on the case that most needs
#      one — a diff that DELETES a test. A mutation harness that silently mutates
#      nothing reports green, which is a false green in the gate whose entire
#      purpose is refusing to accept unverified claims.
#
#   3. EXECUTE THE AUTHOR'S CONTROL COMMAND AND CHECK THE CLAIMED OUTCOME.
#      Rejected as circular. The author supplies both the command and the outcome,
#      so a command that trivially passes satisfies it, and "the claimed outcome"
#      is free prose no parser owns. It would EXECUTE something without
#      establishing that the something is a control — motion, not evidence.
#
# WHAT THE REPLAY CAN AND CANNOT CONCLUDE — the reason this file refuses nothing
#
# Replaying the old test against unchanged production code yields two outcomes:
#
#   old RED  → the change was NECESSARY. The old test genuinely failed against the
#              code as it stands, and the diff is what fixed it. Real signal, and
#              the strongest thing a test-only diff can say for itself. (This is
#              exactly the control Carl ran by hand on drop-hub-bars-var-assertion:
#              the pre-fix file against the new engine gave exactly 1 failure at
#              exactly the line he deleted.)
#
#   old GREEN → NO SIGNAL, and — this is the load-bearing part — the cause is NOT
#              RECOVERABLE from the run. A passing old test means the same thing
#              for a test that was RENAMED, a test that was MOVED, twelve
#              duplicated listener blocks CONSOLIDATED into one helper, a pure
#              readability refactor, and coverage that was quietly DELETED. The
#              first four are legitimate work; the last is the thing the control
#              exists to catch. One observation, five explanations.
#
# So this gate REPORTS the verdict and never refuses on it. That asymmetry is
# deliberate and it is the difference between an evidence gate and a safety gate:
# a safety gate should fail closed, but a false REFUSAL here lands on a rename —
# on legitimate work — and the reliable consequence of a gate that refuses correct
# work is that people stop claiming the shape. The shape then dies and takes its
# real check (the claimability allowlist, the full-suite cert) with it. Refusing
# what it cannot judge would cost more than it collects.
#
# What the gate DOES demand is that the run HAPPENED, fingerprint-bound to this
# exact code — see CertEvidence::CONTROL_LANE. And on a NO-SIGNAL verdict
# bin/dor-check asks the author for the one thing a machine cannot supply: the
# sentence explaining WHICH of the five explanations this is. A sentence is a
# cheap ask; a refusal is not.
#
# WHAT IS OUT OF REACH, STATED RATHER THAN PAPERED OVER (the e2e_onchain lesson
# from config/feature_shapes.yml: never register a lane nothing runs)
#
#   * ADDED files have no pre-change version. There is nothing to replay — not
#     "hard to replay", nothing. Structurally unmechanizable; stays the reviewer
#     prompt, with the builder-supplied mutation the config already asks for.
#   * e2e/ (Playwright) and tests/ (Anchor) pre-change files are replayable in
#     PRINCIPLE and not by this runner: one needs a booted server and the other a
#     funded validator, which is the same "it cannot be a cert lane" argument that
#     removed `e2e_onchain`. Named as deferred rather than silently counted green.
#
# Measured against this repo's real history (86 test-only commits, 2026-08-11):
# 68 (79.1%) carry a replayable Ruby minitest file, 15 (17.4%) are e2e-only, 3
# (3.5%) are added-only. So the executed half covers about four in five, and the
# other one in five is REPORTED as deferred — never counted as a passed control.
module ControlReplay
  LANE = CertEvidence::CONTROL_LANE

  # The only files a lane in this ecosystem can replay standalone: Ruby minitest
  # files, run by `bin/rails test <paths>`. Deliberately NOT every path under
  # `test/` — a fixture, a `test_helper.rb`, or a support module is not a runnable
  # unit, and pretending otherwise would report a green from a run that executed
  # nothing (see #2 in the header for why an empty run reporting green is the
  # failure mode this module is most careful about).
  RUNNABLE_RE = %r{\Atest/.+_test\.rb\z}

  # Verdict tokens, embedded in the evidence line. ONE definition, written by
  # bin/control-check and read back by bin/dor-check, so the writer and the grader
  # cannot drift apart — the same reason FullSuiteGate delegates its line format to
  # CertEvidence rather than re-spelling it.
  NECESSARY = "NECESSARY"
  NO_SIGNAL = "NO-SIGNAL"
  HEAD_RED = "HEAD-RED"
  VERDICTS = [NECESSARY, NO_SIGNAL, HEAD_RED].freeze

  Change = Struct.new(:status, :path, :old_path, keyword_init: true)

  module_function

  # Parse `git diff --name-status -M <base>...HEAD` into Changes.
  #
  # Rows are tab-separated; rename/copy rows carry TWO paths (old, new) and a
  # similarity score on the status letter (R100, C075). Everything else carries
  # one. `old_path` is nil when the file did not exist at the base — which is the
  # single fact the partition below turns on, so it is computed here rather than
  # re-derived by each caller.
  def parse_name_status(text)
    text.to_s.split("\n").filter_map do |row|
      fields = row.split("\t").map(&:strip).reject(&:empty?)
      next if fields.size < 2

      letter = fields[0][0].to_s.upcase
      case letter
      when "R", "C"
        next if fields.size < 3

        # A COPY's destination is new content (its source is untouched), so only a
        # RENAME carries a pre-change version forward to the new path.
        Change.new(status: letter, path: fields[2], old_path: letter == "R" ? fields[1] : nil)
      when "A"
        Change.new(status: "A", path: fields[1], old_path: nil)
      when "D", "M", "T"
        Change.new(status: letter, path: fields[1], old_path: fields[1])
      end
    end
  end

  # Split the diff into the three populations the gate treats differently:
  #
  #   replay     — has a pre-change version AND is a runnable Ruby test file. The
  #                executed half. Carries the OLD path (what gets restored+run).
  #   deferred   — has a pre-change version but no runner here (e2e/, tests/,
  #                fixtures, helpers). Replayable in principle; reported, not run.
  #   added      — no pre-change version. Nothing to replay, ever.
  #
  # Returns paths, sorted and de-duplicated, so a caller's command line and a
  # stamped evidence line are stable across runs (a verdict that reorders itself
  # between two runs of the same code reads as a change that isn't one).
  def partition(changes)
    replay = []
    deferred = []
    added = []
    Array(changes).each do |change|
      old = change.old_path.to_s
      if old.empty?
        added << change.path.to_s
      elsif runnable?(old)
        replay << old
      else
        deferred << old
      end
    end
    { replay: replay.uniq.sort, deferred: deferred.uniq.sort, added: added.uniq.sort }
  end

  def runnable?(path)
    path.to_s.strip.delete_prefix("./").match?(RUNNABLE_RE)
  end

  # The paths that exist at HEAD and are runnable — the "post-change" half of the
  # control. Renames and modifications contribute their NEW path; deletions
  # contribute nothing (there is no post-change file to run).
  def head_runnable(changes)
    Array(changes).filter_map do |change|
      next if change.status == "D"

      path = change.path.to_s
      path if runnable?(path)
    end.uniq.sort
  end

  # The verdict, from the two runs. `old_failed` is the replay of the PRE-CHANGE
  # files; `head_failed` is the current files.
  #
  # HEAD-RED outranks the rest: if the post-change tests do not pass, the
  # before/after comparison is not the interesting fact about this diff. It is
  # reported, not refused — the full-suite cert is what actually blocks a red
  # tree, and duplicating that refusal here would turn an environment-flaky run of
  # a handful of files into a second, weaker gate on the same property.
  def verdict(old_failed:, head_failed:)
    return HEAD_RED if head_failed
    return NECESSARY if old_failed

    NO_SIGNAL
  end

  # The verdict token embedded in a `[control@<fp>] …` line, or nil. Read by
  # bin/dor-check to decide whether to ALSO require the author's explanation.
  # Anchored on the token list so an unrecognized word reads as nil (no verdict)
  # rather than as a passing one.
  def verdict_of(line)
    text = line.to_s
    VERDICTS.find { |token| text.include?(token) }
  end

  # The human-readable half of the evidence line — what the reviewer reads on the
  # task, and what makes the stamp satisfy dor-check's "names a file from this
  # diff" check without the author retyping it.
  # `old_failed`/`head_failed` are BOOLEANS, deliberately: the runner's authority
  # is the test process's EXIT STATUS, and rendering that as a failure COUNT would
  # invent a number the harness never measured (a red run with 7 failures and one
  # with 1 are both just "non-zero exit" here). The runner appends minitest's own
  # summary line when it printed one; that is where a real count comes from.
  def detail(verdict:, replay:, deferred:, added:, old_failed:, head_failed:)
    parts = ["#{verdict} —"]
    parts << "replayed #{replay.size} pre-change file(s) vs current production code:"
    parts << "pre-change #{old_failed ? 'RED' : 'GREEN'}, post-change #{head_failed ? 'RED' : 'GREEN'}."
    parts << "files: #{replay.join(', ')}."
    parts << "DEFERRED (no runner here): #{deferred.join(', ')}." if deferred.any?
    parts << "ADDED (no pre-change version): #{added.join(', ')}." if added.any?
    parts << explanation(verdict)
    parts.join(" ")
  end

  def explanation(verdict)
    case verdict
    when NECESSARY
      "The pre-change test FAILED against unchanged production code, so this diff was necessary."
    when NO_SIGNAL
      "The pre-change test PASSED, so the replay distinguishes nothing — a rename, a move, a " \
        "consolidation and a deleted assertion all look like this. Review judges; see the author's " \
        "[control] line for which it is."
    else
      "The post-change tests did not pass, so the before/after comparison is not this diff's headline."
    end
  end
end

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
# proving "this repo runs no playwright lane" needs that repo checked out, which
# is the per-repo tier-collectability work filed as /tasks/dor-check-tiers-per-repo.
# This asserts something weaker and durable: every app the studio manages has a
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

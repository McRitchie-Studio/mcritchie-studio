# frozen_string_literal: true

# [docs] A ZAP STALES TWO LANES, NOT ONE — and the cheap lane clears both.
#
#   ruby -Itest test/docs/zap_control_lane_docs_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT THIS CLOSES (/tasks/zap-protocol-stales-the-cert). Its sibling,
# zap_cert_freshness_docs_test.rb, pins WHICH pushes stale the builder's CERT. This
# file pins the two things that sat next to that and were never written down:
#
#   (1) THE CONTROL STALES, on a `test-only` PR, from the tree move — and only
#       bin/control-check clears it. Measured live at the G2 review of
#       fixture-rev-helper-hides-failure (PR #1505): one reviewer zap flipped
#       bin/dor-check from PASS to "DoR-to-Merge NOT met" on TWO counts, and a
#       reviewer who re-certified watched one of them stay exactly where it was.
#       The local cert lane has since retired (DevOps v3 phase 2b); the control is
#       the fingerprint-bound lane that remains, graded through CertEvidence.
#
#   (2) THE SUITE EVIDENCE IS THE SETTLED GREEN CI. bin/dor-check reads the PR's CI
#       verdict in both roles; a pending CI is a WAIT for the builder and a refusal
#       for review. The prose tests that once held seven surfaces to the retired
#       full-suite wording were deleted in trim-docs-guard-tests (2026-09-25): the
#       local full suite is gone, and the gate states its own rule.
#
# EVERY ASSERTION READS SOURCE TEXT, never a loaded constant: these are claims ABOUT
# files, and a guard that imports the thing it is guarding drifts with it.

require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/ci_gate"

class ZapControlLaneDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC = File.join(ROOT, "docs/agents/modules/zap-protocol.md")

  def source(rel) = File.read(File.join(ROOT, rel))
  def doc = File.read(DOC)

  # The section this file is about, sliced on its own heading so an edit to the
  # cert paragraph above it cannot silently empty this guard.
  def after_the_zap_section
    body = doc[/^### After a reviewer zap.*/m]
    refute_nil body, "the '### After a reviewer zap' section is gone or renamed — re-point this guard; the " \
                     "two-lane staleness it documents is measured below and is still live"
    body
  end

  # --- (1) THE CONTROL LANE ---------------------------------------------------

  # The mechanism the doc asserts, read off the gate. If control evidence ever stops
  # being graded by the tree fingerprint, the doc's "stales on a tree move" claim
  # becomes false and this fails FIRST — before a reviewer follows it.
  def test_the_control_stamp_is_graded_by_the_tree_fingerprint
    body = source("bin/dor-check")
    # Anchored on column-zero `def`/`end`: this is a top-level method, and a lazy
    # slice to the first indented `end` stops inside its own guard clause.
    fn = body[/^def control_evidence_status\(.*?^end$/m]
    refute_nil fn, "bin/dor-check no longer defines control_evidence_status — re-point this guard"

    assert_match(/CertEvidence\.lane_status\(/, fn,
                 "control_evidence_status no longer grades the control with CertEvidence.lane_status. The " \
                 "doc tells a reviewer the control stales on a tree move BECAUSE it is fingerprint-graded — " \
                 "if that stopped being true, the doc is now wrong")
    assert_match(/fingerprint/, fn,
                 "control_evidence_status no longer resolves a fingerprint — the whole 'stales with the " \
                 "cert' claim rests on the stamp being tree-bound")
  end

  # The scope claim. The doc tells readers NOT to go looking for a stale control on a
  # PR that cannot have one, and that narrowing is only honest while exactly one shape
  # declares the evidence.
  def test_test_only_is_the_only_shape_that_declares_control_evidence
    shapes = YAML.load_file(File.join(ROOT, "config/feature_shapes.yml"))
    shapes = shapes["shapes"] || shapes
    declaring = shapes.select { |_name, d| d.is_a?(Hash) && Array(d["required_evidence"]).include?("control") }

    assert_equal ["test-only"], declaring.keys.sort,
                 "the shapes declaring `required_evidence: [control]` are now #{declaring.keys.sort.inspect}. " \
                 "zap-protocol.md narrows the stale-control warning to `test-only` ALONE — a second declaring " \
                 "shape makes that narrowing wrong in the direction that loses evidence, so widen the doc in " \
                 "the same change"
  end

  # The two runners, and the asymmetry in what a WRONG ROOT costs you. The doc says
  # fast-check refuses loudly and control-check does not refuse at all; both halves are
  # load-bearing, because only one of them tells the operator anything.
  def test_the_preflight_refuses_a_wrong_root_and_the_control_writer_does_not
    assert_match(/TaskTree\.refusal\(/, source("bin/fast-check"),
                 "bin/fast-check no longer takes TaskTree.refusal. The doc leans on that refusal: it is the " \
                 "LOUD half of the loud/silent pair this section teaches")

    refute_match(/TaskTree\.refusal\(/, source("bin/control-check"),
                 "bin/control-check now REFUSES a wrong root. That is an improvement — and it falsifies the " \
                 "doc, which warns that this runner succeeds from the wrong tree and stamps a fingerprint " \
                 "nothing can match. Delete that warning rather than leaving a scare in place")

    assert_match(/RepoRoot\.code_root\(/, source("bin/control-check"),
                 "bin/control-check no longer roots at the cwd's git toplevel via RepoRoot.code_root — the " \
                 "doc names that resolution (and CONTROL_CHECK_ROOT) as the reason standing in the desk matters")
  end

  # The RECOVERY BLOCK — the three ordered steps, sliced on its own lead so the
  # forward-pointers elsewhere in the section (the table row, the seam note) cannot
  # satisfy this guard by merely mentioning the runner somewhere.
  def control_recovery_block
    body = after_the_zap_section[/\*\*ON A `test-only` PR THE CONTROL STALES.*?(?=\n\*\*OPEN QUESTION)/m]
    refute_nil body, "the stale-control recovery block is gone or renamed — re-point this guard; the two-lane " \
                     "staleness it documents was measured on PR #1505 and is still live"
    body
  end

  # The doc half: the recovery must name the control runner, and must move the desk
  # BEFORE it. Order is the finding — a control stamped against a tree that is about
  # to change is stale on arrival.
  def test_the_recovery_moves_the_desk_before_the_control
    flat = control_recovery_block.gsub(/\s+/, " ")

    assert_match(%r{bin/control-check}, flat,
                 "the recovery never names bin/control-check. A reviewer who re-runs the gate is left with a " \
                 "STALE error and no command that clears it — the exact dead end measured on PR #1505")
    refute_match(%r{bin/(?:full-suite)-check}, flat, "the retired local full suite is never offered")

    # ORDER IS PINNED ON THE FENCED RECIPE, not on the paragraph. What a reader copies
    # is the block.
    recipe = control_recovery_block[/```bash\n(.*?)```/m, 1]
    refute_nil recipe, "the recovery no longer prints a copyable block — the steps are ordered, and prose " \
                       "alone lets a reader run them in any order"

    move = recipe.index(/\bmerge --ff-only\b/)
    control_writer = recipe.index(%r{bin/control-check})

    refute_nil move, "the recipe no longer MOVES the desk onto the zapped head. The control fingerprints " \
                     "the WORKING tree, so it stays stale without it"
    refute_nil control_writer, "the recipe names no control writer — nothing clears the STALE stamp"
    assert move < control_writer,
           "the recipe runs the control BEFORE moving the desk — a control stamped against a tree that " \
           "is about to change is stale on arrival"
  end

  # The forward pointer at the seam. A reviewer who applies a zap is told, where they
  # are standing, that a green CI is not the whole verdict — the omission that made
  # this whole section invisible to the reviewer who needed it.
  def test_the_apply_a_zap_recipe_points_past_the_ci_to_this_section
    seam = doc[/\*\*Apply it\*\* when the fix is in zap bounds.*?(?=\n### After a reviewer zap)/m]
    refute_nil seam, "the reviewer 'Apply it' recipe is gone or renamed — re-point this guard"

    flat = seam.gsub(/\s+/, " ")
    assert_match(/STALE/, flat,
                 "the reviewer seam still ends on the CI without warning that the push staled a " \
                 "fingerprint-bound lane. 'Merge-ready plus a green CI' is what the MERGE needs; it is not " \
                 "what bin/dor-check grades, and a reviewer who stops reading here meets the refusal cold")
  end

  # Every git command this section prints against the PR branch names its tree. Same
  # rule the sibling file pins on the cert paragraph, for the same measured reason: a
  # bare fast-forward pasted from the primary moves the PRIMARY.
  def test_every_printed_branch_command_names_its_checkout
    unscoped = after_the_zap_section.gsub(/\s+/, " ").scan(%r{git (?!-C )(?:[a-z-]+ )+?origin/<branch>})

    assert_empty unscoped,
                 "the section prints #{unscoped.inspect} against the PR branch with no directory. A reviewer " \
                 "runs --gate-role review from the primary, which sits on release or main by SOP, so the " \
                 "unscoped form fast-forwards THAT checkout onto the feature head and exits 0"
  end

  # --- (2) THE RE-CERT LANE ---------------------------------------------------

  # The ruling, read off the gate rather than off either document. Since
  # /tasks/dor-reads-settled-ci-verdict there is no route ladder: the suite evidence is
  # the PR's settled GREEN CI in BOTH roles, and the one role split left is that a
  # pending CI is a WAIT for the builder and a refusal for review. The recovery recipe
  # above is kept for the CONTROL lane, which is still fingerprint-graded.
  def test_the_suite_evidence_is_the_settled_green_ci_in_both_roles
    body = source("bin/dor-check")

    refute_match(/suite_route = "fast/, body,
                 "bin/dor-check has grown a fast/provisional route again — the docs say the receipts are inert")
    refute_match(/FullSuiteGate|full_suite_gate/, body,
                 "bin/dor-check grades a cert receipt again; the CI verdict is the whole suite gate")
    assert_includes CiGate::ONLY_EVIDENCE, "settled GREEN GitHub CI",
                    "the one-evidence sentence must name the settled green"
    assert CiGate.waiting?({ state: :pending }, review_role: false), "a builder-side pending CI is a WAIT"
    refute CiGate.waiting?({ state: :pending }, review_role: true), "review's gate-zero refuses a pending CI"
    refute CiGate.waiting?({ state: :green }, review_role: false)
  end
end

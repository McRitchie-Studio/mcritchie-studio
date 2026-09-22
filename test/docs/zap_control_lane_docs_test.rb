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
#   (1) THE CONTROL STALES TOO, on a `test-only` PR, from the same tree move — and
#       the cert writers do not clear it. Measured live at the G2 review of
#       fixture-rev-helper-hides-failure (PR #1505): one reviewer zap flipped
#       bin/dor-check from PASS to "DoR-to-Merge NOT met" on TWO counts, and a
#       reviewer who re-certified watched one of them stay exactly where it was.
#       `[control@<fp>]` is graded by the same FullSuiteGate machinery as the certs,
#       so it is the same trigger with a different writer: bin/control-check.
#
#   (2) THE RE-CERT DOES NOT HAVE TO BE THE FULL SUITE. bin/dor-check's route ladder
#       has no `test-only` branch and the FAST route has no `review_role` condition,
#       so a fast cert plus a settled green CI is accepted in the review lane exactly
#       as at submit. Three agent docs read stricter than that and said `test-only`
#       "still owes the full-suite cert"; on 2026-09-21 a builder read one of them
#       and ran 11,004 tests the gate never wanted. The docs are now corrected to
#       "owes the cert gate" (i.e. is not exempt, unlike `docs`), and the tests below
#       pin BOTH halves — the gate's behaviour, and the prose that describes it —
#       because correcting one and not the other is how the claim in the sibling
#       file survived its first pass.
#
# EVERY ASSERTION READS SOURCE TEXT, never a loaded constant: these are claims ABOUT
# files, and a guard that imports the thing it is guarding drifts with it.

require "minitest/autorun"
require "yaml"

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
  # being graded by the cert's fingerprint machinery, the doc's "same trigger" claim
  # becomes false and this fails FIRST — before a reviewer follows it.
  def test_the_control_stamp_is_graded_by_the_same_fingerprint_machinery_as_the_certs
    body = source("bin/dor-check")
    # Anchored on column-zero `def`/`end`: this is a top-level method, and a lazy
    # slice to the first indented `end` stops inside its own guard clause.
    fn = body[/^def control_evidence_status\(.*?^end$/m]
    refute_nil fn, "bin/dor-check no longer defines control_evidence_status — re-point this guard"

    assert_match(/FullSuiteGate\.lane_status\(/, fn,
                 "control_evidence_status no longer grades the control with FullSuiteGate.lane_status. The " \
                 "doc tells a reviewer the control stales on the SAME trigger as the cert BECAUSE it is the " \
                 "same machinery — if that stopped being true, the doc is now wrong")
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

  # The two writers, and the asymmetry in what a WRONG ROOT costs you. The doc says
  # fast-check refuses loudly and control-check does not refuse at all; both halves are
  # load-bearing, because only one of them tells the operator anything.
  def test_the_cert_writer_refuses_a_wrong_root_and_the_control_writer_does_not
    assert_match(/CertRootGuard\.refusal\(/, source("bin/fast-check"),
                 "bin/fast-check no longer takes CertRootGuard.refusal. The doc leans on that refusal twice: " \
                 "it is why a reviewer cannot certify from their throwaway zap desk, and it is the LOUD half " \
                 "of the loud/silent pair this section teaches")

    refute_match(/CertRootGuard\.refusal\(/, source("bin/control-check"),
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

  # The doc half: the recovery must name the control runner, and must not imply a
  # re-cert clears it. Order is the finding — cert writer, THEN control writer.
  def test_the_recovery_runs_the_control_after_the_cert
    flat = control_recovery_block.gsub(/\s+/, " ")

    assert_match(%r{bin/control-check}, flat,
                 "the recovery never names bin/control-check. A reviewer who re-certifies and re-runs the gate " \
                 "is left with a second STALE error and no command that clears it — the exact dead end " \
                 "measured on PR #1505")

    # ORDER IS PINNED ON THE FENCED RECIPE, not on the paragraph. The prose around it
    # names both writers to say what each one does NOT clear, and indexing on the
    # literal finds that mention first — the same trap the sibling file hit and
    # documented. What a reader copies is the block.
    recipe = control_recovery_block[/```bash\n(.*?)```/m, 1]
    refute_nil recipe, "the recovery no longer prints a copyable block — the three steps are ordered, and " \
                       "prose alone lets a reader run them in any order"

    move = recipe.index(/\bmerge --ff-only\b/)
    cert_writer = recipe.index(%r{bin/(?:fast|full-suite)-check})
    control_writer = recipe.index(%r{bin/control-check})

    refute_nil move, "the recipe no longer MOVES the desk onto the zapped head. Both lanes fingerprint the " \
                     "WORKING tree, so both stay stale without it"
    refute_nil cert_writer, "the recipe names no cert writer — both lanes are stale and it clears one"
    refute_nil control_writer, "the recipe names no control writer — it clears the cert and leaves the " \
                               "second STALE error exactly where PR #1505 found it"

    assert move < cert_writer,
           "the recipe re-certifies BEFORE moving the desk. Order is the whole finding — a cert taken in that " \
           "order stamps the tree the reader already had, and the lane stays STALE"
    assert cert_writer < control_writer,
           "the recipe runs the control BEFORE the cert writer. Move, re-certify, then re-run the control — " \
           "a control stamped against a tree that is about to change is stale on arrival"
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

  # The ruling, read off the ladder rather than off either document. The FAST route is
  # role-independent; the PROVISIONAL route is builder-only. That asymmetry is the
  # whole reason a reviewer may clear a stale cert with bin/fast-check.
  def test_the_fast_route_is_role_independent_and_the_provisional_route_is_not
    lines = source("bin/dor-check").lines
    guard_for = lambda do |route|
      idx = lines.index { |l| l =~ /^\s*suite_route = "#{Regexp.escape(route)}"\s*$/ }
      refute_nil idx, "bin/dor-check no longer assigns suite_route = #{route.inspect} — re-point this guard"
      back = (0...idx).reverse_each.find { |i| lines[i] =~ /^\s*(?:els)?if / }
      refute_nil back, "no condition found above the #{route.inspect} assignment"
      lines[back]
    end

    fast = guard_for.call("fast")
    provisional = guard_for.call("fast-provisional")

    refute_match(/review_role/, fast,
                 "the FAST route now carries a review_role condition. Three agent docs (claude.md, index.md, " \
                 "devops-cycle-design.md) and zap-protocol.md all tell a REVIEWER that bin/fast-check plus a " \
                 "green CI clears a stale cert — if that is no longer true they are all wrong at once")
    assert_match(/review_role/, provisional,
                 "the PROVISIONAL route lost its review_role condition. It is the builder-only half of this " \
                 "pair, and the docs contrast the two explicitly — a fast cert credited against a PENDING CI " \
                 "is exactly what review's gate-zero is strict about")
    assert_match(/green/, fast, "the FAST route no longer requires a green CI — the docs say it does")
  end

  # The shape gate has no test-only branch: `full_suite_gate: true` means NOT EXEMPT,
  # and the route ladder it opens is the ordinary one.
  def test_the_suite_gate_opens_on_the_shapes_own_declaration_not_on_a_named_shape
    body = source("bin/dor-check")
    opener = body[/^if gate != "build" && shape_def && shape_def\.fetch\("full_suite_gate", true\)$/]

    refute_nil opener,
               "the suite gate no longer opens on the shape's own `full_suite_gate` declaration. The corrected " \
               "docs say test-only owes the ORDINARY cert gate because the gate keys on that flag and on " \
               "nothing about the shape's name"

    shapes = YAML.load_file(File.join(ROOT, "config/feature_shapes.yml"))
    shapes = shapes["shapes"] || shapes
    assert_equal true, shapes.dig("test-only", "full_suite_gate"),
                 "test-only no longer declares full_suite_gate: true — the docs' 'not exempt, unlike docs' " \
                 "contrast rests on it"
    assert_equal false, shapes.dig("docs", "full_suite_gate"),
                 "docs no longer declares full_suite_gate: false — it is the other half of the same contrast"
  end

  # The prose half. The falsified wording, refuted in every agent doc that carried it.
  # This constrains nothing about how the correction is phrased.
  def test_no_agent_doc_says_test_only_owes_the_full_suite_cert
    %w[
      docs/agents/claude.md
      docs/agents/index.md
      docs/agents/system/devops-cycle-design.md
      docs/agents/modules/building-sop.md
    ].each do |rel|
      refute_match(/owes the\s+full-suite cert/i, source(rel),
                   "#{rel}: still says test-only \"owes the full-suite cert\". Measured on the ladder above, " \
                   "the gate accepts a fast cert plus a green CI for this shape exactly as for a feature. A " \
                   "builder who read this on 2026-09-21 ran 11,004 tests the gate never asked for — say " \
                   "\"owes the cert gate\" (not exempt), or name the local full suite as the CI-independent " \
                   "option it is")
    end
  end
end

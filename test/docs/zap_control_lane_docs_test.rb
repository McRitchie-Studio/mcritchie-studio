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

  # EVERY SURFACE THAT STATES THE RULE — and this list IS the guard's scope.
  # Its first version named four agent docs, which is what a doc-shaped correction
  # could reach. Two ENFORCEMENT surfaces state the same rule and were not on it:
  # `config/feature_shapes.yml`, the shape contract itself, and
  # `bin/session-preflight`, which prints this sentence at the moment a builder is
  # deciding what to run — the costliest place to be wrong. The SCRIPT was covered
  # (test/commands/session_preflight_test.rb, 36 cases); this SENTENCE was read by
  # no test until 2026-09-22, which is the gap that let it go stale.
  FAST_OR_FULL_SURFACES = %w[
    docs/agents/claude.md
    docs/agents/index.md
    docs/agents/modules/fast-lane.md
    docs/agents/system/devops-cycle-design.md
    docs/agents/modules/building-sop.md
    config/feature_shapes.yml
    bin/session-preflight
  ].freeze

  # WHY COLLAPSED. Every file here wraps its prose, so a literal-space regex reads
  # clean over text that is plainly present — the phrase simply straddles a line
  # break. The previous guard matched `/owes the\s+full-suite cert/i`, which pins
  # ONE of the two gaps and leaves "owes<NEWLINE>the" through. A repo-wide scan on
  # collapsed text is what found the `bin/session-preflight` site.
  def flat(rel) = source(rel).gsub(/\s+/, " ")

  # The prose half. The falsified wording, refuted on every surface that carried
  # it. This constrains nothing about how the correction is phrased.
  def test_no_surface_says_test_only_owes_the_full_suite_outright
    FAST_OR_FULL_SURFACES.each do |rel|
      body = flat(rel)

      refute_match(/owes\s+the\s+full-?suite\s+cert/i, body,
                   "#{rel}: still says test-only \"owes the full-suite cert\". Measured on the ladder above, " \
                   "the gate accepts a fast cert plus a green CI for this shape exactly as for a feature. A " \
                   "builder who read this on 2026-09-21 ran 11,004 tests the gate never asked for — say " \
                   "\"owes the cert gate\" (not exempt), or name the local full suite as the CI-independent " \
                   "option it is")

      # The same claim wearing the shape contract's own words. `full_suite_gate: true`
      # is NOT EXEMPT; rendering it as "the full-suite evidence is required exactly as
      # for a feature" reads as "run it locally" to everyone who stops before the
      # trailing clause, which is how this file briefed the 11,004-test run.
      refute_match(/full-?suite[^.]{0,80}required\s+exactly\s+as\s+for\s+a\s+feature/i, body,
                   "#{rel}: states the cert gate as full-suite evidence \"required exactly as for a " \
                   "feature\". What a feature owes is the GATE, satisfied by a full cert OR a fast cert " \
                   "alongside a settled green CI — say which, because the lead clause is where readers stop")
    end
  end

  # THE OPPOSITE MISREADING, which costs a merge rather than a suite. Strip the
  # green-CI conjunct and "a fast cert satisfies it" becomes false exactly when it
  # matters — the review gate-zero is an allow-list, so a pending, red or unreadable
  # CI refuses and only a FULL cert stands in. A surface that grants the fast route
  # without naming its condition has traded one wrong brief for another.
  FAST_ROUTE = /fast[-\s]?(?:cert|check)/i
  GREEN_CI   = /green[^.]{0,30}\bCI\b|\bCI\b[^.]{0,15}green/i
  # The sentence must be ABOUT this gate. Without this clause the assertion passed
  # on `docs/agents/index.md` for the wrong reason entirely — it matched the
  # SUBMIT-SIDE provisional-credit paragraph ("a fast cert is credited
  # provisionally... a red CI still blocks"), which is a different rule in a
  # different section, while that file's real grant says `bin/fast-check` and would
  # not have matched a /fast cert/ pattern at all. A whole-file regex cannot tell
  # those apart; asking one SENTENCE to carry route + condition + subject can.
  CERT_GATE_SUBJECT = /test-?only|full_suite_gate|cert gate|exempt/i

  def test_every_surface_states_the_green_ci_condition
    FAST_OR_FULL_SURFACES.each do |rel|
      qualifying = flat(rel).split(/(?<=[.!?])\s+/).select do |sentence|
        sentence.match?(FAST_ROUTE) && sentence.match?(GREEN_CI) && sentence.match?(CERT_GATE_SUBJECT)
      end

      refute_empty qualifying,
                   "#{rel}: names the fast route for this gate without naming its CONDITION in the " \
                   "same sentence. Since /tasks/dor-reads-settled-ci-verdict the cert gate is satisfied " \
                   "by a SETTLED GREEN CI for the PR's head and by nothing else (bin/lib/ci_gate.rb#verdict); " \
                   "bin/fast-check is an optional pre-flight, not evidence the gate reads. Say the green " \
                   "beside the fast route, and say which condition differs between the lanes: the ROLE — " \
                   "review's gate-zero refuses a pending CI, the BUILDER reads it as a WAIT (CiGate.waiting?)"
    end
  end

  # THE ANTI-PERMISSIVE CLAUSE IS ITS OWN DEFECT, and this exists because the
  # first correction of the over-strict wording shipped one (review of PR 1522,
  # 2026-09-22). Refuting "test-only owes the full suite" invites the opposite
  # overshoot — naming the LOCAL full suite as what to reach for when CI is not
  # green — and that is false in the cell that costs the most.
  #
  # MEASURED at 91e634d3 against a test-only fixture carrying a real
  # [fast-cert@<tree>], both roles, via DOR_CHECK_SUITE_EVIDENCE + DOR_CHECK_CI_STATUS:
  #
  #   evidence        CI         builder              review
  #   fast cert only  green      met                  met
  #   fast cert only  PENDING    MET (exit 0)         not met
  #   fast cert only  none       MET (exit 0)         not met
  #   fast cert only  red        not met              not met
  #   FULL cert       RED        NOT MET (exit 1)     —
  #
  # So a local full suite is the answer in exactly ONE cell — an UNREADABLE
  # verdict. On PENDING the builder is already satisfied by the fast cert
  # (the `fast-provisional` route), so a full run there is the 11,004-test waste this file
  # exists to prevent; and on RED it does not help at all, because red is fixed
  # by fixing CI. This asserts the NEGATIVE only — it constrains nothing about how
  # a surface phrases the provisional credit, it just refuses the one claim that
  # sends a builder to the suite when the gate has already passed.
  LOCAL_FULL_SUITE = /local full[-\s]?suite|full[-\s]?suite\s+(?:cert|run)|certif\w*\s+(?:locally|in full)/i
  PENDING_CELL     = /\bpending\b/i

  def test_no_surface_offers_the_local_full_suite_for_a_pending_ci
    FAST_OR_FULL_SURFACES.each do |rel|
      offenders = flat(rel).split(/(?<=[.!?])\s+/).select do |sentence|
        sentence.match?(LOCAL_FULL_SUITE) && sentence.match?(PENDING_CELL)
      end

      assert_empty offenders,
                   "#{rel}: names the LOCAL full suite in the same sentence as a PENDING CI. At submit a " \
                   "fresh fast cert is ALREADY credited provisionally on a pending CI " \
                   "(bin/dor-check's `fast-provisional` route), so the gate has passed and the local " \
                   "run buys nothing — that is the same waste as the over-strict wording this file " \
                   "refutes, one cell over. The local full suite is for an UNREADABLE verdict; a RED CI " \
                   "is fixed by fixing CI, not by certifying locally (a FULL cert against a red CI is " \
                   "NOT MET, exit 1). If you are describing this defect rather than committing it, keep " \
                   "the two clauses in separate sentences."
    end
  end
end

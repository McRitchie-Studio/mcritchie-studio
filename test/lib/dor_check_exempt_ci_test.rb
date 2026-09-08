# frozen_string_literal: true

# The EXEMPT (doc-only) path must read CI. Standalone — no Rails; the integration
# tier shells bin/dor-check with --file fixtures:
#   ruby -Itest test/lib/dor_check_exempt_ci_test.rb
#
# THE BUG (/tasks/gate-zero-skips-docs-ci). bin/dor-check's exempt-kind branch ended
# in a bare `exit 0`, and that `exit` sat ABOVE two things: the CI allow-list (whose
# own comment says ":green is the ONLY state that PASSES") and the
# gate-verdict emit. So `--gate-role review` — the run the pipeline calls THE
# AUTHORITATIVE CI VERDICT — never evaluated CI on a doc-only diff. --json returned
# ready=true, exempt=true, errors=[] with no `ci` key at all, and no `dor_review`
# attempt was written. Three doc-shaped PRs cleared gate-zero that way (turf-vault
# #9/#10, mcritchie-studio #1204); every one happened to be green, so the exposure
# was the next one.
#
# THE NULL ATTEMPT WAS THE SAME FACT, TWICE MISREAD. `dor_review` reading null on
# docs-shaped PRs was logged twice and filed as a cosmetic gap in the record. It was
# not a missing record: the gate had not run. So test_the_exempt_verdict_records_a
# _gate_attempt_in_both_directions is not a nicety — it pins the only observable the
# defect ever produced.
#
# WHAT MUST *NOT* CHANGE, and why this is a split rather than a moved block. Two
# unrelated guards lived below that `exit`, and only one of them should be skipped
# here: the shape/TEST-TIER gate is correctly waived (a prose diff owes no unit
# tier), while the CI allow-list never had any business being skipped — this repo's
# CI GRADES PROSE (doc-link checks, generated-doc drift, entry-doc guards, rubocop
# over bin/). "Ships no behavior" is not "cannot fail CI".
# test_the_tier_gate_is_still_waived_on_a_green_exempt_diff and its code-carrying
# control are what hold that line: relocating the CI block above the exit would pass
# every OTHER test in this file and fail those two.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ci_gate"

class DorCheckExemptCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  DOC_DIFF = "docs/agents/modules/deployment.md"
  CODE_DIFF = "app/models/thing.rb"

  # An exempt KIND with a doc-only diff — the shape the gate waives tiers for.
  def devops(overrides = {})
    {
      "kind" => "docs", "pr_url" => PR_URL,
      "acceptance" => ["Runbook names the deploy strategy"],
      "repositories" => ["myapp"], "risk_tags" => ["docs"],
      "test_plan" => ["[unit] n/a"], "post_deploy_cmd" => "none"
    }.merge(overrides)
  end

  # Runs dor-check against an in-memory task, returns [parsed_json, exitcode].
  # STDOUT only: the child inherits bundler's env under `bin/rails test` and emits
  # rubygems warnings on STDERR, which would corrupt the --json parse if merged.
  # `pr_files:` defaults to the SAME list the diff is injected from — the readable
  # world, where the PR read succeeded and the exemption is proven against the PR
  # itself. Pass "unreadable"/"unverified" to drive the FAILED-read worlds, where a
  # non-PR source stands in and the exemption would otherwise be granted against an
  # artifact nobody asked about. It is a separate dimension from `changed:` for the
  # reason refusal()'s header states: a fixture that can only vary them together
  # cannot express the failure it is pinning.
  def check(devops_payload, ci: nil, role: "review", changed: DOC_DIFF, gate_bin: nil, args: "--json",
            pr_files: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "exempt-task", "title" => "T",
                                     "metadata" => { "devops" => devops_payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => pr_files || changed,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_GATE_BIN" => gate_bin
      }.compact)
      out = IO.popen(env, "#{BIN} exempt-task --file #{path} #{args} --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      args.include?("--json") ? [JSON.parse(out), code] : [out, code]
    end
  end

  def errors_of(verdict) = Array(verdict["errors"]).join(" | ")

  # A recording stub for the gate CLI: every invocation's argv, one line per call.
  # This is the ONLY way to observe the durable attempt — --json and --file both
  # skip the board write by design, so a gate that records nothing and a gate that
  # records a pass are otherwise indistinguishable from a test.
  def with_gate_stub
    Dir.mktmpdir do |dir|
      log = File.join(dir, "gate-calls.log")
      bin = File.join(dir, "gate-stub")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
      SH
      FileUtils.chmod(0o755, bin)
      yield bin, -> { File.exist?(log) ? File.readlines(log, chomp: true) : [] }
    end
  end

  # ── [unit] CiGate — the decision table both paths now share ─────────────────
  #
  # Pure: no subprocess, no ENV, no board. The exempt path's whole fix is that it
  # asks THIS instead of asking nothing, so the states it must refuse are asserted
  # here directly rather than inferred from a verdict's prose.
  #
  # READ "ADVANCES" AT THIS GRAIN. Here it means CiGate returns no error, and green
  # really is alone in that. It is NOT the same question as whether the REVIEW
  # advances: the caller may waive a no-verdict refusal on a full cert. Driven
  # through `bin/dor-check --gate-role review` on a task carrying a FULL cert,
  # :none, :unverified and :unreadable each reach ready=true exit=0 ON THE GATED
  # PATH — the wording bin/lib/ci_gate.rb's own allow-list note already uses. That
  # is why the refusal PRINTED for an unclassified state says PASSING and not
  # advances (/tasks/gate-prose-overclaims-again).
  #
  # THOSE FOUR WORDS ARE THE WHOLE SENTENCE, AND THIS IS THE FILE THAT OWES THEM
  # (/tasks/exempt-path-claim-unqualified). The claim landed here UNQUALIFIED — in
  # the EXEMPT path's own test file, where it is false. Driven the same way, same
  # FULL cert, on a docs-KIND task with a doc-only diff, all three REFUSE:
  #
  #   injected      ci.state      gated            exempt
  #   green         green         ready=true  0    ready=true   0
  #   none          none          ready=true  0    ready=false  1
  #   unverified    unverified    ready=true  0    ready=false  1
  #   unreadable    unreadable    ready=true  0    ready=false  1
  #
  # The exempt caller passes `cert_route: false` (bin/dor-check's exempt branch), so
  # tier 2 collapses into tier 3 and green is alone in ADVANCING here as well as in
  # passing. The unqualified sentence read as true only because the clause before it
  # said the caller MAY waive — conditionality smuggled in by a neighbour. That
  # accidental rescue is what this prose family keeps living on; name the path
  # instead.

  def test_unit_green_is_the_only_state_that_advances_a_review
    error, = CiGate.verdict({ state: :green }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_nil error, "green must advance"
  end

  def test_unit_every_non_green_state_refuses_a_review
    %i[red pending conflicted ci_less closed merged none unreadable unverified no_pr].each do |state|
      error, = CiGate.verdict({ state: state }, review_role: true, pr_url: PR_URL, slug: "t")
      refute_nil error, "#{state} must refuse a review"
    end
  end

  # THE ALLOW-LIST PROPERTY, not a longer deny-list: a state this gate has never
  # heard of refuses too. Testing only the real tokens cannot tell an allow-list
  # from a deny-list, and the difference is a live false pass.
  def test_unit_an_unclassified_state_refuses_rather_than_falling_through
    error, clears = CiGate.verdict({ state: :teal }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes error.to_s, "does not classify"
    refute clears, "an unclassified state is not the no-verdict family and no cert clears it"
  end

  def test_unit_a_blank_pr_url_refuses_and_no_cert_can_clear_it
    error, clears = CiGate.verdict({ state: :no_pr }, review_role: true, pr_url: "", slug: "t")
    assert_includes error.to_s, "BLANK"
    refute clears, "the missing thing is the SUBJECT, not the evidence"
  end

  # The role split is load-bearing and must survive the extraction: the builder's
  # submit-side run is provisional by construction, so a pending CI is a note there
  # and a refusal in review.
  def test_unit_a_pending_ci_notes_for_the_builder_and_refuses_for_review
    error, _clears, notes = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                           review_role: false, pr_url: PR_URL, slug: "t")
    assert_nil error
    assert_includes notes.join(" "), "NO LONGER blocks"

    review_error, = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                   review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes review_error.to_s, "still RUNNING"
  end

  def test_unit_gate_row_names_ci_as_the_failing_sop_when_ci_is_why_it_failed
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
    # THE REFUSED GREEN. The stale-green refusal fires only when ci[:state] == :green,
    # so this vector is the one that decides whether `review_refused` is wired to
    # anything at all on that path. It graded "pass" until 2026-09-07: the review
    # refused while the gates card recorded CI as passing.
    assert_equal "fail", CiGate.gate_row({ state: :green }, review_role: true, review_refused: true)
    # …and the builder-side pending row, unchanged. NOTE it is pinned only for
    # review_refused: false — the refused variant is unreachable (CiGate.verdict makes a
    # builder-side :pending a NOTE, not a ci_error), so asserting one would pin a state
    # no caller can construct.
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :red }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: true)
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: true)
    assert_nil CiGate.gate_row(nil, review_role: true, review_refused: false)
  end

  # ── [integration] the exempt path, end to end through bin/dor-check ─────────

  # THE REGRESSION. Written first, and it failed against the old `exit 0`:
  # ready=true, exempt=true, errors=[], no `ci` key.
  def test_a_red_ci_refuses_an_exempt_doc_only_review
    verdict, code = check(devops, ci: "red")

    assert_equal 1, code, "a red CI must refuse an exempt diff"
    refute verdict["ready"], "ready must follow the CI verdict, not the exemption"
    assert verdict["exempt"], "the TIER waiver is unchanged — only the CI verdict refuses"
    assert_includes errors_of(verdict), "GitHub CI is RED"
    assert_equal "red", verdict.dig("ci", "state")
  end

  # THE FIELD WHOSE ABSENCE MADE THE DEFECT INVISIBLE. An exempt verdict carried no
  # `ci` key at all, so no monitor could tell a green from a gate that never looked.
  def test_an_exempt_pass_still_publishes_the_ci_verdict_it_read
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "green", verdict.dig("ci", "state")
    assert_equal "pass", verdict["ci_gate_result"]
    assert_empty Array(verdict["errors"])
  end

  # THE NEIGHBOURS, not just red. The documented allow-list refuses each of these,
  # and an exempt task is no different.
  def test_pending_unreadable_and_unclassified_ci_all_refuse_an_exempt_review
    {
      "pending" => "still RUNNING",
      "unreadable" => "UNREADABLE",
      "unverified" => "no verdict yet",
      "none" => "no verdict yet",
      "conflicted" => "gate-zero",
      "closed" => "not an OPEN review target",
      "state:teal" => "does not classify"
    }.each do |injected, expected|
      verdict, code = check(devops, ci: injected)

      assert_equal 1, code, "#{injected} must refuse"
      assert_includes errors_of(verdict), expected
      assert_equal "fail", verdict["ci_gate_result"], "#{injected} must record CI as the failing sop"
    end
  end

  # A BLANK pr_url resolves to :no_pr WITHOUT any injection — the real path, and the
  # state whose silent fall-through is what the allow-list was written to close.
  def test_a_blank_pr_url_refuses_an_exempt_review
    verdict, code = check(devops("pr_url" => ""))

    assert_equal 1, code
    assert_includes errors_of(verdict), "devops.pr_url is BLANK"
    assert_equal "no_pr", verdict.dig("ci", "state")
  end

  # The builder's submit-side run stays provisional: review re-reads it, so a
  # pending CI is a note and a missing PR is silent. A fix that blocked BOTH roles
  # would stall every docs handoff on an hour-old token.
  def test_the_builder_role_keeps_its_provisional_treatment
    pending, code = check(devops, ci: "pending", role: "builder")
    assert_equal 0, code, "submit-side pending must not block"
    assert_includes Array(pending["suggestions"]).join(" "), "NO LONGER blocks"

    no_pr, no_pr_code = check(devops("pr_url" => ""), role: "builder")
    assert_equal 0, no_pr_code, "submit-side runs before the PR exists"
    assert_empty Array(no_pr["errors"])

    red, red_code = check(devops, ci: "red", role: "builder")
    assert_equal 1, red_code, "a RED CI blocks in BOTH roles"
    assert_includes errors_of(red), "GitHub CI is RED"
  end

  # ── the exempt path must CONFIRM that it IS exempt ─────────────────────────
  #
  # THE HOLE (/tasks/exempt-path-trusts-local-tree). The gated path role-splits a
  # failed PR-file read — ERROR for review, SUGGESTION for the builder — because the
  # reviewer's checkout is deliberately NOT the task's tree, so grading a substitute
  # there is the false pass gate-zero exists to refuse. The EXEMPT path had no such
  # split: `pr_read_alert` landed in `suggestions` for BOTH roles, so a doc-only
  # exemption could be earned from whatever tree the reviewer happened to be standing
  # in while the PR itself went unread. Measured on this branch before the fix: the
  # review and builder verdicts came back byte-identical, both `✓ … → ready to
  # advance submitted → reviewed`, off `[source: git working tree]`.
  #
  # SISTER DEFECT TO /tasks/gate-zero-skips-docs-ci, one door out. That one was "the
  # exempt path never asks CI"; this is "the exempt path never confirms it IS exempt."
  # Both let a review gate pass on evidence it did not actually read.
  #
  # BOTH FAILED-READ STATES, because only one of them was ever closed. A REVIEW-role
  # `:unreadable` is caught upstream in resolve_branch_diff (diff_source
  # :pr_unreadable → nothing observed → the "could not be proven doc-only" refusal),
  # but `:unverified` — gh missing, a 404, a transport error, an API outage — is a
  # FAILED read too, and it was never in that guard: it fell through to the local
  # working tree and reached the grant. Pinning only the credential state would
  # re-close the door that was already shut and leave the open one open.
  FAILED_PR_READS = %w[unreadable unverified].freeze

  def test_a_failed_pr_file_read_refuses_the_review_exemption
    # THE CONTROL FIRST, so this test cannot pass by refusing everything: the same
    # task, the same green CI, a READABLE PR file list — still exempt, still ready.
    readable, readable_code = check(devops, ci: "green", role: "review")
    assert_equal 0, readable_code, "a readable PR read must still earn the exemption:\n#{readable}"
    assert readable["ready"], "the control must pass, or the assertions below prove nothing"

    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, ci: "green", role: "review", pr_files: state)

      assert_equal 1, code, "review + pr_files:#{state} must REFUSE the exemption:\n#{verdict}"
      refute verdict["ready"], "pr_files:#{state} — a gate that did not read the PR is not ready"
      assert_includes errors_of(verdict), ALERT_MARK,
                      "pr_files:#{state} — the refusal must be an ERROR, not a suggestion"
      assert_empty Array(verdict["suggestions"]).grep(/#{ALERT_MARK}/),
                   "pr_files:#{state} — the alert must MOVE to errors, not be printed twice"
    end
  end

  # THE FENCE (acceptance 2). The builder's local-tree fallback is DELIBERATE: they
  # stand in the task's own worktree, where the local view is the honest near-twin of
  # the PR, and their verdict is provisional by design. A fix that refused both roles
  # would stall every docs handoff behind an hour-old App token and buy no integrity.
  # Same unreadable input as the test above — only the role differs.
  def test_the_builder_role_keeps_its_local_tree_fallback_on_a_failed_pr_read
    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, ci: "green", role: "builder", pr_files: state)

      assert_equal 0, code, "submit-side pr_files:#{state} must stay provisional:\n#{verdict}"
      assert verdict["ready"], "pr_files:#{state} — the builder's exemption still stands"
      assert_empty Array(verdict["errors"]), "pr_files:#{state} — nothing is an error submit-side"
      assert_includes Array(verdict["suggestions"]).join(" "), ALERT_MARK,
                      "pr_files:#{state} — but the substitution is NAMED, never silent"
    end
  end

  # THE RECEIPT SURVIVES THE PROMOTION. `pr_read` is how a monitor asks "was the PR
  # actually read?" of a verdict after the fact, and it used to be keyed off the
  # SUGGESTION list — so promoting the alert to an error would have blanked the field
  # in exactly the role where it matters most. Keyed off the refusal itself now.
  # THE BUILD GATE STAYS LENIENT, review role or not — the clause that says so must
  # not be inert. Measured: removing `gate != "build"` from the role split left every
  # other test in this file green, which is precisely the half-inert guard this task's
  # own discipline warns about. The build gate resolves no diff and must not shell
  # `gh`, so a PR read that failed there is not evidence of anything; line 2356's
  # gated-path twin carries the same clause for the same reason.
  def test_the_build_gate_never_refuses_on_a_failed_pr_read
    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, role: "review", pr_files: state, args: "--json --gate build")

      assert_equal 0, code, "the build gate has no PR to judge (pr_files:#{state}):\n#{verdict}"
      assert_empty Array(verdict["errors"]), "pr_files:#{state} — nothing is an error at the build gate"
    end
  end

  def test_the_refused_read_is_recorded_on_the_exempt_payload_in_both_roles
    %w[review builder].each do |role|
      verdict, = check(devops, ci: "green", role: role, pr_files: "unverified")
      assert_equal "unverified", verdict.dig("pr_read", "state"),
                   "#{role}: the payload must record WHICH read failed"
    end
  end

  # ── [integration] the world the defect actually lived in ───────────────────
  #
  # Every case above injects the diff (DOR_CHECK_CHANGED_FILES), which is the
  # deterministic seam but NOT the shape of the bug: it short-circuits the resolver
  # before any fallback happens. Here the seam is absent and a REAL git tree stands
  # in — one dirty, unrelated prose file in a checkout that is not the PR. That is
  # the hub PRIMARY on a review night, and the file is the one that actually did it
  # on 2026-08-08: docs/agents/maintenance/delete-later.md.
  DIRTY_PROSE = "docs/agents/maintenance/delete-later.md"

  # A checkout whose only change is one unrelated prose file — no injected diff, so
  # the gate must fall back to (or refuse) the working tree. The task file lives
  # OUTSIDE the repo: inside, it reads as a code diff and the exemption never applies.
  def with_prose_only_checkout(role:, pr_files:)
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.email", "t@t.t", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.name", "T", out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "README.md"), "base\n")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-qm", "base", out: File::NULL, err: File::NULL)
      FileUtils.mkdir_p(File.join(dir, File.dirname(DIRTY_PROSE)))
      File.write(File.join(dir, DIRTY_PROSE), "one unrelated dirty note\n")

      Dir.mktmpdir do |taskdir|
        file = File.join(taskdir, "task.json")
        File.write(file, JSON.generate("slug" => "exempt-task", "title" => "T",
                                       "metadata" => { "devops" => devops }))
        env = OutboundSeams.env({
          "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
          "DOR_CHECK_PR_FILES" => pr_files, "DOR_CHECK_CI_STATUS" => "green"
        })
        out = IO.popen(env, "#{BIN} exempt-task --file #{file} --gate-role #{role} 2>/dev/null", &:read)
        yield out, $?.exitstatus
      end
    end
  end

  def test_a_reviewer_standing_in_a_foreign_prose_dirty_checkout_is_refused
    with_prose_only_checkout(role: "review", pr_files: "unverified") do |out, code|
      assert_equal 1, code, "the 2026-08-08 shape must REFUSE in the review role:\n#{out}"
      refute_includes out, "\u2192 ready to advance",
                      "a doc-only exemption earned off an unread PR is the false pass:\n#{out}"
      assert_includes out, ALERT_MARK
      # AND THE CLOSING LINE MUST NAME THE RIGHT REFUSAL. CI is GREEN in this
      # fixture, so a verdict that signs off "this refusal is the CI verdict" is
      # pointing the reader at the one thing that did not fail.
      assert_includes out, "the PR's own file list going unread",
                      "the refusal must say WHICH half refused:\n#{out}"
      refute_includes out, "the CI verdict, which an exempt diff does not escape",
                      "CI is green here — blaming it is the misnamed-refusal defect:\n#{out}"
    end
  end

  # THE SAME TREE, THE SAME REFUSED READ, THE BUILDER ROLE — still granted, and still
  # NAMED. This is the pair that proves the fix is role-scoped rather than a blanket
  # offline refusal, on input identical but for --gate-role.
  def test_the_same_tree_still_earns_the_builders_provisional_exemption
    with_prose_only_checkout(role: "builder", pr_files: "unverified") do |out, code|
      assert_equal 0, code, "the builder's provisional fallback must survive:\n#{out}"
      assert_includes out, "[source: git working tree]",
                       "the fixture must actually exercise the local-tree fallback:\n#{out}"
      assert_includes out, "ready to advance"
      assert_includes out, ALERT_MARK
    end
  end

  # ── the half that must stay skipped ────────────────────────────────────────

  # THE SCOPE GUARD. The task carries NO checks_run and no shape, and still passes on
  # a green CI: the tier gate is waived exactly as before. Relocating the CI block
  # above the exit instead of splitting the path passes the CI tests above and fails
  # this one, because the tier gate would come with it.
  def test_the_tier_gate_is_still_waived_on_a_green_exempt_diff
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert_empty Array(verdict["missing_tiers"]), "a prose diff owes no unit tier"
    assert_empty Array(verdict["missing_metadata"])
    refute_includes errors_of(verdict), "tier"
  end

  # THE CONTROL for the line above: the exemption is EARNED FROM THE DIFF, so a
  # code-carrying diff under the same exempt kind falls through to the full gate and
  # IS asked for tiers. Without this, "no tier was demanded" could mean the gate is
  # waiving them for everyone.
  def test_a_code_carrying_diff_under_an_exempt_kind_is_still_gated
    verdict, code = check(devops, ci: "green", changed: CODE_DIFF)

    assert_equal 1, code
    refute verdict["exempt"], "code in the diff loses the exemption"
    assert_includes errors_of(verdict), "ships a code diff"
  end

  # ── the durable attempt ────────────────────────────────────────────────────

  # ACCEPTANCE 2. `dor_review` read null on every docs-shaped PR because the exempt
  # path exited above the emit. Both directions are asserted: a gate that only
  # records its refusals leaves the same hole for every green.
  def test_the_exempt_verdict_records_a_gate_attempt_in_both_directions
    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "green", gate_bin: stub, args: "")
      assert_equal 0, code
      green_calls = calls.call
      assert(green_calls.any? { |c| c.start_with?("open task exempt-task dor_review") },
             "a green exempt review must OPEN a dor_review attempt — got #{green_calls.inspect}")
      assert(green_calls.any? { |c| c.start_with?("close task exempt-task dor_review --success") },
             "and close it successful — got #{green_calls.inspect}")
    end

    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "red", gate_bin: stub, args: "")
      assert_equal 1, code
      red_calls = calls.call
      assert(red_calls.any? { |c| c.start_with?("close task exempt-task dor_review --failed") },
             "a refused exempt review must record a FAILED attempt — got #{red_calls.inspect}")
      assert(red_calls.any? { |c| c.include?('"sop":"ci"') && c.include?('"result":"fail"') },
             "and CI must be named as the failing sop — got #{red_calls.inspect}")
    end
  end

  # The builder's run closes `dor`, not `dor_review` — one verdict per gate. A
  # single emit that always wrote dor_review would make every submit look like a
  # review verdict on the gates card.
  def test_the_builder_role_records_the_dor_gate_not_dor_review
    with_gate_stub do |stub, calls|
      check(devops, ci: "green", role: "builder", gate_bin: stub, args: "")
      recorded = calls.call
      assert(recorded.any? { |c| c.start_with?("open task exempt-task dor ") || c == "open task exempt-task dor" },
             "builder-side must open `dor` — got #{recorded.inspect}")
      refute(recorded.any? { |c| c.include?("dor_review") }, "…and never dor_review — got #{recorded.inspect}")
    end
  end

  # The waiver is SAID OUT LOUD, in the text verdict a human actually reads. The old
  # line named only the skipped tier gate, so "no tier was demanded" and "no CI was
  # read" printed identically.
  def test_the_text_verdict_names_the_ci_state_behind_an_exempt_pass
    out, code = check(devops, ci: "green", args: "")

    assert_equal 0, code
    assert_includes out, "shape/test-tier gate skipped"
    assert_includes out, "GitHub CI: GREEN"
  end

  def test_the_text_refusal_says_the_tier_gate_was_still_waived
    out, code = check(devops, ci: "red", args: "")

    assert_equal 1, code
    assert_includes out, "the shape/test-tier gate IS waived"
    assert_includes out, "GitHub CI is RED"
  end

  # The build gate resolves no diff and must not shell `gh` — so it reads no CI and
  # writes no attempt. Leniency there cannot disarm anything: at design time no code
  # exists yet and the build gate enforces no tiers either way.
  def test_the_build_gate_reads_no_ci_on_an_exempt_task
    verdict, code = check(devops, ci: "red", args: "--json --gate build")

    assert_equal 0, code, "the build gate has no CI verdict to give"
    assert_nil verdict["ci"]
  end

  # ══ THE GATE MUST HONOUR THE REMEDY IT PRINTS — ON BOTH PATHS ════════════════
  #
  # THE DEFECT (/tasks/exempt-refusal-prints-dead-remedy). The exempt path took the
  # GATED path's refusal verbatim — "certify in full instead: `bin/full-suite-check
  # <slug>`" — while bin/dor-check discarded the `cert_clears` flag that was the only
  # thing able to honour it. Measured before the fix: adding that exact cert produced
  # a BYTE-IDENTICAL refusal. The gate printed an instruction it could not honour, and
  # an operator who followed it burned a full-suite run for nothing.
  #
  # WHY A TEST AND NOT A CAREFUL COMMENT. This bug is a MESSAGE that outran its
  # BEHAVIOUR, and the two live in different files. Nothing structural held them
  # together, so they drifted the moment a second caller appeared — and the same class
  # of drift produced five false comments in this ecosystem in one day, several
  # written by people fixing false comments. Prose cannot hold prose honest.
  #
  # HOW THIS PIN WORKS, and why it is a PROPERTY rather than a pair of cases: it does
  # not know which path offers a cert. It READS THE PRINTED REFUSAL, decides from that
  # text alone what the gate promised, and then EXECUTES the promise:
  #
  #   promised a cert     → running with a FULL cert MUST advance (exit 0).
  #   promised no cert    → running with a FULL cert MUST still refuse, and the
  #                         refusal must be BYTE-IDENTICAL — which is the defect's own
  #                         signature, asserted here as the PROOF that the denial is
  #                         accurate rather than as the bug.
  #
  # So neither half can move alone. Re-arm the cert route on the exempt path without
  # rewording, and the identical-refusal branch fails. Reword either message without
  # moving the behaviour, and the executed-promise branch fails. Both are mutated
  # separately in this file's sibling checks (see the task's mutation evidence).

  # THE CONTRACT CLAUSES. Each is spelled ONCE in the source (bin/lib/ci_gate.rb and
  # bin/lib/ci_status.rb) and read here to classify a refusal. They are deliberately
  # the wording an operator acts on, not an internal token: the thing under test IS
  # what the reader is told.
  OFFERS_CERT = "certify in full instead"
  DENIES_CERT = "no local cert stands in"

  # The GATED twin of `devops` — a code diff under a shaped bug, which is the path
  # where a full cert genuinely does stand in. Same states, same binary, opposite
  # answer; that contrast is what makes the property meaningful rather than a
  # restatement of the exempt path.
  GATED_CODE_DIFF = "app/models/thing.rb"

  def gated_devops(overrides = {})
    {
      "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
      "acceptance" => ["Gate honours the remedy it prints"],
      "repositories" => ["myapp"], "risk_tags" => ["gates"],
      "test_plan" => ["[unit] x", "[integration] y"], "post_deploy_cmd" => "none",
      "checks_run" => ["[unit] bin/rails test test/x_test.rb",
                       "[integration] ruby -Itest test/lib/y_test.rb"]
    }.merge(overrides)
  end

  # Runs the REAL binary on either path with a stated suite-evidence world, and
  # returns [stdout, exitcode]. `evidence` is named at every call site with no
  # default, for the reason dor_check_test.rb states about its own `evidence:`:
  # accidental coverage of the cert dimension is one refactor from vanishing, and the
  # cert dimension is the entire subject here.
  # `pr_files:` IS A SEPARATE DIMENSION FROM `ci:`, AND THAT IS THE WHOLE POINT.
  # This helper used to pin DOR_CHECK_PR_FILES to the readable diff, which made
  # pr_read_alert nil in every case the property ever saw — so the property could not
  # observe the ONE state where the two halves of a verdict disagreed, and the gate
  # shipped an exempt refusal that DENIED a cert in the CI error and OFFERED one four
  # lines later in the PR-read suggestion. One stale token refuses BOTH reads, so
  # :unreadable co-fires on the PR file list and the check list; a fixture that can
  # only vary one of them cannot express the normal shape of the failure it is pinning
  # (/tasks/exempt-refusal-prints-dead-remedy, bounce 1).
  #
  # DOR_CHECK_CHANGED_FILES stays set: it is what keeps an unreadable PR read on the
  # EXEMPT branch. Without it a review-role run resolves diff_source :pr_unreadable,
  # observes nothing, and refuses at the "could not be proven doc-only" branch instead
  # — a different gate with a different contract, deliberately not this property's
  # subject.
  def refusal(path, ci:, evidence:, pr_files: :readable)
    payload, changed = path == :exempt ? [devops, DOC_DIFF] : [gated_devops, GATED_CODE_DIFF]
    injected_pr_files = pr_files == :readable ? changed : "unreadable"
    Dir.mktmpdir do |dir|
      file = File.join(dir, "task.json")
      File.write(file, JSON.generate("slug" => "remedy-task", "title" => "R",
                                     "metadata" => { "devops" => payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => injected_pr_files,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_SUITE_EVIDENCE" => evidence
      })
      out = IO.popen(env, "#{BIN} remedy-task --file #{file} --gate-role review 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  FULL_CERT = "ok"              # bin/full-suite-check — ci.yml's own command, locally
  FAST_CERT_ONLY = "fast_fresh" # bin/fast-check — diff-mapped, not a stand-in for CI

  # THE PROPERTY. Read the promise off the printed refusal, then execute it.
  #
  # RUN OVER BOTH PR-READ WORLDS ON THE EXEMPT PATH. `:readable` is the isolated case
  # (only the check read was refused); `:unreadable` is the NORMAL one, where a single
  # stale token refuses the PR file list and the CI in the same run, so a verdict
  # carries the CI gate's refusal AND the PR-read alert together. The second world is
  # what the first cut of this pin could not reach, and it is the world the defect
  # lived in.
  #
  # THE GATED PATH IS RUN ON `:readable` ONLY, AND THE REASON IS A MEASUREMENT, NOT AN
  # OVERSIGHT. Adding gated×:unreadable to this list fails TODAY, and it failed
  # identically before this task touched anything: in the REVIEW role the PR-read alert
  # is an ERROR (grading a substitute for a refused read is the false pass gate-zero
  # exists to refuse), and no cert clears an error about the DIFF — so the verdict
  # names `bin/full-suite-check`, the operator runs it, the CI half duly clears, and
  # the run still exits 1 on the PR-read half. That is a real dead remedy, PRE-EXISTING
  # and unchanged in exposure by this task, and it is not fixable by flipping this
  # caller: `cert_route: false` prints the doc-only denial ("the shape/test-tier gate
  # is already waived"), which is false on a code diff. It wants a THIRD route — "this
  # refusal is not the suite gate's at all" — shared with bin/dor-check's "could not be
  # proven doc-only" branch and bin/release.rb's G3 gate. That is its own task; this
  # comment is the handle, and this line is where the pin extends to when it lands.
  def test_every_no_verdict_refusal_is_honoured_exactly_as_printed
    [%i[exempt readable], %i[exempt unreadable], %i[gated readable]].each do |path, pr_files|
      %w[none unverified unreadable].each do |state|
        label = "#{path}/#{state}/pr_files:#{pr_files}"
        refused, code = refusal(path, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_equal 1, code, "#{label} must refuse without a full cert:\n#{refused}"

        offered = refused.include?(OFFERS_CERT)
        denied  = refused.include?(DENIES_CERT)
        # THE ASSERTION THAT CAUGHT THIS. A verdict may promise a cert or deny one; a
        # verdict that does BOTH has two printers disagreeing inside one refusal, and
        # the operator acts on whichever they read first. That is exactly what an
        # unreadable PR file list produced on the exempt path.
        refute_equal offered, denied,
                     "#{label} must either OFFER a cert or DENY one, never both or neither:\n#{refused}"

        certified, cert_code = refusal(path, ci: state, evidence: FULL_CERT, pr_files: pr_files)

        if offered
          assert_equal 0, cert_code,
                       "#{label} PRINTED #{OFFERS_CERT.inspect} — the gate must honour the remedy " \
                       "it prints:\n#{certified}"
          assert_match(/ready to advance/, certified)
        else
          assert_equal 1, cert_code,
                       "#{label} PRINTED #{DENIES_CERT.inspect}, so a full cert must NOT advance " \
                       "it:\n#{certified}"
          # THE DEFECT'S OWN SIGNATURE, now the proof of honesty. Before the fix this
          # sameness sat under a refusal that had just recommended the cert; the
          # denial is only accurate if the cert truly changes nothing.
          assert_equal refused, certified,
                       "#{label} says a cert does not stand in — so adding one must change " \
                       "NOTHING, byte for byte"
        end
      end
    end
  end

  # THE DIRECTION, asserted separately. The property above would still hold if BOTH
  # paths flipped together, which would be a deliberate policy change and must not
  # pass silently. This is the policy: a doc-only diff has no suite left to
  # substitute, so it gets no cert route; a code diff does.
  #
  # ALSO RUN WITH THE PR FILE LIST REFUSED, because that is where the direction was
  # actually broken: the CI half denied the cert and the PR-read half offered it, in
  # one verdict. `refute_includes … OFFERS_CERT` over the WHOLE exempt refusal is what
  # states the property at verdict grain rather than per-printer — a second printer
  # cannot reintroduce the offer without failing here.
  def test_the_exempt_path_denies_the_cert_route_and_the_gated_path_offers_it
    %i[readable unreadable].each do |pr_files|
      %w[none unverified unreadable].each do |state|
        label = "#{state}/pr_files:#{pr_files}"
        exempt_refusal, = refusal(:exempt, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_includes exempt_refusal, DENIES_CERT,
                        "the exempt refusal must say plainly that no cert stands in (#{label})"
        refute_includes exempt_refusal, OFFERS_CERT,
                        "NO printer in an exempt verdict may name a route it cannot honour (#{label}):\n" \
                        "#{exempt_refusal}"

        gated_refusal, = refusal(:gated, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_includes gated_refusal, OFFERS_CERT,
                        "the gated refusal must still name the cert that clears its CI verdict (#{label})"
        refute_includes gated_refusal, DENIES_CERT,
                        "a full cert DOES stand in for the gated path's unread CI verdict; denying it " \
                        "would be the mirror defect (#{label})"
      end
    end
  end

  # THE CONTROL FOR THE VARIANT ABOVE: prove the new input actually reaches the path.
  # A `pr_files: :unreadable` run that silently behaved like a readable one would make
  # every assertion above pass while testing nothing — the fixture-cannot-express-the-
  # bug failure. So assert the PR-read alert is PRESENT when the read is refused and
  # ABSENT when it is not; that alert is the second printer, and its presence is the
  # precondition for the offer/denial collision this task fixes.
  ALERT_MARK = "so this verdict did NOT read the PR"

  def test_the_unreadable_pr_file_list_variant_actually_reaches_the_second_printer
    with_alert, = refusal(:exempt, ci: "unreadable", evidence: FAST_CERT_ONLY, pr_files: :unreadable)
    assert_includes with_alert, ALERT_MARK,
                    "the pr_files: :unreadable world must actually fire pr_read_alert:\n#{with_alert}"

    without_alert, = refusal(:exempt, ci: "unreadable", evidence: FAST_CERT_ONLY, pr_files: :readable)
    refute_includes without_alert, ALERT_MARK,
                    "the readable world must NOT fire it, or the two worlds are the same test"
  end

  # ── [unit] the flag and the text come from ONE parameter ────────────────────
  #
  # The integration property above proves the two agree through the real binary. This
  # proves they CANNOT disagree at the source: `cert_route` decides the returned
  # `cert_clears` AND the wording, so there is no state in which a caller is handed a
  # clearable refusal whose text denies the cert (or the reverse). That was exactly
  # the defect's shape — bin/dor-check received `cert_clears = true`, discarded it,
  # and printed the offer the discarded flag was the only thing able to honour.
  def test_unit_cert_route_governs_the_flag_and_the_wording_together
    %i[none unverified unreadable].each do |state|
      ci = { state: state, reason: "403", cause: :permissions }

      offered, clears = CiGate.verdict(ci, review_role: true, pr_url: PR_URL, slug: "t", cert_route: true)
      assert clears, "#{state}: the gated path's refusal must be clearable by a full cert"
      assert_includes offered, OFFERS_CERT, "#{state}: a clearable refusal must name the route"
      refute_includes offered, DENIES_CERT

      denied, no_clears = CiGate.verdict(ci, review_role: true, pr_url: PR_URL, slug: "t", cert_route: false)
      refute no_clears, "#{state}: the exempt path's refusal must NOT be clearable"
      assert_includes denied, DENIES_CERT, "#{state}: an unclearable refusal must say so"
      refute_includes denied, OFFERS_CERT, "#{state}: it must not name a route it cannot honour"
    end
  end

  # The states OUTSIDE the no-verdict family never carried a cert route in either
  # direction, and must not grow one from this change: `cert_route` is about which
  # refusals a cert may clear, not about widening the family that may be cleared.
  def test_unit_cert_route_does_not_widen_the_no_verdict_family
    %i[red conflicted closed merged no_pr teal].each do |state|
      _error, clears = CiGate.verdict({ state: state, failing: ["ci"] },
                                      review_role: true, pr_url: PR_URL, slug: "t", cert_route: true)
      refute clears, "#{state} is not the no-verdict family — no cert clears it, whatever cert_route says"
    end
  end

  # THE THIRD COPY of a sentence corrected twice already (PR #1128 fixed
  # pr-review-primary.md and dor.md). "No check will ever appear" was justified by
  # "solana-studio and turf-vault carry zero workflows"; re-derived at source
  # 2026-09-05 on origin/accepted AND origin/main, solana-studio ships
  # .github/workflows/gem-ci.yml and turf-vault ships .github/workflows/ci.yml. The
  # claim is false, so the refusal must not rest on it — when a check genuinely never
  # arrives that is :conflicted / :ci_less, each with its own remedy.
  def test_unit_the_no_verdict_refusal_no_longer_blames_a_repo_without_workflows
    %i[none unverified].each do |state|
      message, = CiGate.verdict({ state: state }, review_role: true, pr_url: PR_URL, slug: "t",
                                                  cert_route: true)
      refute_match(/NO workflows at all/, message,
                   "#{state}: every repo here ships a pull_request workflow — that premise is false")
      refute_match(/no check will ever appear/i, message,
                   "#{state}: 'never' is a property of the PR's merge state (:conflicted/:ci_less), not a repo")
    end
  end

  # ── [unit] THE CALL-SITE REGISTRY — a comment that checks itself ────────────
  #
  # WHY THIS EXISTS. `CiStatus.unreadable_remedy` carries a comment naming every
  # production caller and the route each is on. The first version of that comment said
  # "every caller that predates the parameter is on the gated path", and it was FALSE
  # at two callers on the day it was written — one of which (bin/dor-check's
  # pr_read_alert on the exempt path) was the live defect that bounced this PR. Prose
  # about call sites goes stale the moment someone adds a call site, and nothing in a
  # code review reliably notices.
  #
  # So the list is pinned to the SOURCE. This does not judge whether a route is
  # correct — that is the property test's job, above, which executes the printed
  # promise. It judges only that the set of callers is the set the comment describes:
  # add a caller, delete one, or flip one between "states its route" and "takes the
  # default", and this fails and hands the author the comment to update.
  #
  # THE HASH IS KEYED BY FILE PATH, so on its own it can only ever audit the files
  # someone thought to type. The FILE SET is therefore globbed and asserted
  # separately — see `bin_files` and the set test below, which is what makes "add a
  # caller" true of a caller added in a FILE THIS HASH HAS NEVER HEARD OF.
  #
  # NUMBERS, and the reason for each:
  #   bin/lib/ci_gate.rb  1 stating / 0 default — unread_ci_refusal forwards its own
  #                       cert_route:, and both CiGate.verdict callers state it.
  #   bin/dor-check       1 stating / 3 default — the stating one is pr_read_alert,
  #                       which FORWARDS its callers' route (see below); the three
  #                       defaults are the suite gate's TWO unreadable-CI refusals —
  #                       the FAST-cert branch and the DEFERRED one, each in its
  #                       BUILDER half — plus the submit-side note, all on the GATED
  #                       path where a cert genuinely clears. The deferred half joined
  #                       them in /tasks/deferred-unreadable-skips-role-split: it had
  #                       been pointing at a CI error only the REVIEW role raises, so
  #                       submit-side it named a remedy that was not in the errors.
  #   bin/pr-review       1 stating / 0 default — cert_route: !maybe_exempt.
  #   bin/release.rb      1 stating / 0 default — the G3 pre-QA gate, which STATES
  #                       cert_route: :retired since /tasks/release-offers-retired-cert.
  #                       It is the one entry here that has MOVED: it was 0/1, and the
  #                       pin at 1 default is what brought the fix back to this file.
  #                       Totals went 3/3 → 4/2 in that one diff, and 4/2 → 4/3 when
  #                       the deferred branch above gained its builder half — SEVEN
  #                       callers over FOUR files as of 2026-09-06. This number has
  #                       moved in three consecutive sittings: re-derive it with the
  #                       scan below rather than trusting any figure written here.
  UNREADABLE_REMEDY_CALL_SITES = {
    "bin/lib/ci_gate.rb" => { states_route: 1, takes_default: 0 },
    "bin/dor-check" => { states_route: 1, takes_default: 3 },
    "bin/pr-review" => { states_route: 1, takes_default: 0 },
    "bin/release.rb" => { states_route: 1, takes_default: 0 }
  }.freeze

  # pr_read_alert's OWN callers, counted by route. It prints from six branches and is
  # used as a predicate (`pr_read_alert ? …`) in three more where the string is
  # discarded — the reason the method keeps a default at all.
  #   5 printing callers pass true  — the gated path, the two "could not be proven
  #                                   doc-only" branches, and the two :pr_incomplete
  #                                   branches added by /tasks/dor-check-reads-one-pr
  #                                   (the exempt preamble and the shape-claim refusal
  #                                   for a multi-repo task with one PR unread). All
  #                                   five REFUSE: nothing is waived on any of them, so
  #                                   the exempt denial's premise — "the shape/test-tier
  #                                   gate is already waived, so there is no suite left
  #                                   to substitute" — would be false.
  #   1 printing caller passes false — the EXEMPT path. This is the fix.
  # It went 3 → 5 on 2026-09-07; re-derive it with the scan below rather than trusting
  # the figure written here.
  PR_READ_ALERT_CALL_SITES = { true => 5, false => 1, predicate: 3 }.freeze

  REPO_ROOT = File.expand_path("../..", __dir__)

  # ONE spelling of the call, shared by both scans below. Two literals of the same
  # marker is exactly the drift this section exists to catch, written into the catcher.
  UNREADABLE_REMEDY_MARKER = "CiStatus.unreadable_remedy("

  # Source with FULL-LINE comments removed, so the registry counts CALLS and never the
  # prose about them — this file's own subject is prose drifting from behaviour, and a
  # checker fooled by a comment would be the joke writing itself.
  def code_of(relative)
    File.readlines(File.join(REPO_ROOT, relative))
        .reject { |line| line.strip.start_with?("#") }.join
  end

  # Every `<marker>(` in `source`, with the argument text of each call. Paren-balanced
  # rather than line- or regex-bounded: three of these calls already wrap across lines,
  # and a checker that missed them would under-count silently.
  def calls_to(source, marker)
    args = []
    offset = 0
    while (index = source.index(marker, offset))
      open = index + marker.length
      depth = 1
      cursor = open
      while depth.positive? && cursor < source.length
        depth += 1 if source[cursor] == "("
        depth -= 1 if source[cursor] == ")"
        cursor += 1
      end
      args << source[open...(cursor - 1)]
      offset = cursor
    end
    args
  end

  # THE CANDIDATE SET — GLOBBED, NEVER LISTED, and the reason is a mutation rather
  # than a tidiness preference. UNREADABLE_REMEDY_CALL_SITES is keyed by file path and
  # the count test iterates it, so for its whole life it opened exactly four files.
  # RE-MEASURED IN REVIEW, at this branch's own base (32 tests) and head (33). The
  # first draft of this paragraph quoted a 26-test head — numbers carried over from the
  # older tree the finding was found on, which is precisely the drift this file exists
  # to catch, written into itself. One probe, two placements: injected into
  # bin/dor-check the COUNT test kills it ("Expected: 2" default-takers, found 3); the
  # IDENTICAL caller in a NEW file, bin/lib/carl_probe.rb, SURVIVED the pre-change
  # test at 32 runs, 310 assertions, 0 failures — and is KILLED by the set test below
  # at 33 runs, 316 assertions, 1 failure naming the file. A fifth file was simply
  # never opened.
  #
  # That is more than a test nit, because bin/lib/ci_status.rb's header tells the next
  # reader this registry "fails when [a caller] appears, vanishes, or changes route.
  # Add a caller and the suite makes you classify it." True of the four listed files,
  # FALSE of a new one — so the hole in the test was a hole in a promise the
  # production code makes in prose. Widening the net here is what makes that sentence
  # honest without touching it.
  #
  # EVERY FILE UNDER bin/ — deliberately not `bin/**/*.rb`. Two of the four callers
  # the registry ALREADY names, bin/dor-check and bin/pr-review, are extensionless
  # scripts, so an extension-based glob is born blind to half the known set. Every
  # narrower rule is a hole of the same shape as the one being closed, and the widest
  # rule costs one `include?` over ~140 small text files.
  def bin_files
    Dir.glob("bin/**/*", base: REPO_ROOT)
       .select { |path| File.file?(File.join(REPO_ROOT, path)) }
       .sort
  end

  # THE FILE SET, asserted against the source — the half the per-file counts cannot
  # see. An unclassified file now FAILS loudly instead of going unread.
  def test_unit_the_registry_names_every_file_under_bin_that_calls_unreadable_remedy
    candidates = bin_files

    # CONTROL FIRST: prove the scan READ what it claims to have read. The set
    # assertion below is not vacuous when the glob matches nothing — but it IS
    # satisfied by any glob that reaches all four registry keys and nothing else,
    # which is the same blindness wearing a glob. `bin/**/*.rb` would drop the two
    # extensionless callers; `bin/*` plus `bin/lib/*.rb` would reach all four keys
    # while never descending into bin/lib/dor/checks/. Pin both properties that
    # narrowing destroys.
    %w[bin/dor-check bin/pr-review].each do |script|
      assert_includes candidates, script,
                      "the candidate glob must reach EXTENSIONLESS bin scripts — two of the four " \
                      "known callers are exactly that, so a glob that misses them was never " \
                      "auditing the set it reports on"
    end
    assert candidates.any? { |path| path.count("/") >= 3 },
           "the candidate glob must recurse BELOW bin/<dir>/ — bin/lib/dor/checks/ holds .rb today, " \
           "and a caller parked one level deeper must not be able to hide"

    callers = candidates.select { |path| code_of(path).include?(UNREADABLE_REMEDY_MARKER) }

    assert_equal UNREADABLE_REMEDY_CALL_SITES.keys.sort, callers,
                 "the SET OF FILES calling CiStatus.unreadable_remedy changed. A caller in a file " \
                 "this registry does not name is an unclassified promise about a remedy — decide " \
                 "its route, then update ci_status.rb's call-site list and the registry above. " \
                 "(A registry-only key means a caller vanished; a source-only file means a new one " \
                 "appeared.)\n" \
                 "registry: #{UNREADABLE_REMEDY_CALL_SITES.keys.sort.inspect}\n" \
                 "source:   #{callers.inspect}"
  end

  def test_unit_the_unreadable_remedy_call_site_registry_matches_the_source
    UNREADABLE_REMEDY_CALL_SITES.each do |file, expected|
      args = calls_to(code_of(file), UNREADABLE_REMEDY_MARKER)
      stating, defaulting = args.partition { |arg| arg.include?("cert_route:") }

      assert_equal expected[:states_route], stating.size,
                   "#{file}: callers STATING cert_route: changed. Update the call-site list in " \
                   "CiStatus.unreadable_remedy's header, then this registry — the comment is the " \
                   "deliverable, this test is only what keeps it true.\n#{stating.join("\n---\n")}"
      assert_equal expected[:takes_default], defaulting.size,
                   "#{file}: callers TAKING the cert_route: default changed. A new default-taker is a new " \
                   "promise nobody classified — decide its route, then update ci_status.rb's list and " \
                   "this registry.\n#{defaulting.join("\n---\n")}"
    end
  end

  def test_unit_every_printing_caller_of_pr_read_alert_states_its_route
    source = code_of("bin/dor-check")
    # The definition is not a call site. Dropped ENTIRELY, not renamed: a rename that
    # keeps the identifier as a prefix still matches the bare-use scan below, which is
    # how the first cut of this counted four predicates where three exist.
    source = source.sub(/^def pr_read_alert\(cert_route: true\)$/, "def PR_READ_ALERT_DEFINITION")

    printing = calls_to(source, "pr_read_alert(")
    assert_equal PR_READ_ALERT_CALL_SITES[true], printing.count { |arg| arg.include?("cert_route: true") },
                 "printing callers on the GATED/enforced branches changed:\n#{printing.join("\n---\n")}"
    assert_equal PR_READ_ALERT_CALL_SITES[false], printing.count { |arg| arg.include?("cert_route: false") },
                 "the EXEMPT caller is the one that must pass false — that is this task's whole fix:\n" \
                 "#{printing.join("\n---\n")}"
    assert_equal printing.size, printing.count { |arg| arg.include?("cert_route:") },
                 "a printing caller of pr_read_alert rode the default. That is exactly how the exempt path " \
                 "came to print an offer it could not honour:\n#{printing.join("\n---\n")}"

    # The predicate uses discard the string, so they are allowed to omit the keyword —
    # counted, not merely tolerated, so that a printing caller can never hide among them.
    predicates = source.scan(/pr_read_alert(?!\()/).size
    assert_equal PR_READ_ALERT_CALL_SITES[:predicate], predicates,
                 "bare `pr_read_alert` uses (predicate only — the string is discarded) changed to #{predicates}"
  end

  # ── the closing line that outlived its truth ────────────────────────────────
  #
  # THE DEFECT (/tasks/gate-sentence-outlived-truth). CiStatus.unreadable_remedy's
  # exempt branch closed flatly: "Fixing the credential is the only route — this gate
  # advances on a GREEN CI and nothing else." True when it was written. FALSE since
  # PR #1225 taught this same path to refuse on an unread PR file list as well, which
  # made green NECESSARY here and stopped it being SUFFICIENT. The co-fire is the case
  # that shows it — one stale App token refuses the PR read AND the check read at
  # once, so both halves fire on one verdict and the CI half signs off by promising
  # that fixing the credential and getting a green would carry it. It would not: the
  # PR-read refusal is still standing.
  #
  # WHY THE FIX IS A DERIVATION AND NOT A REWRITE, which is what these two tests are
  # really pinning as a PAIR. The sentence is correct in one world and wrong in
  # another, and the worlds differ by ONE input — whether anything else is refusing.
  # So a fix that reworded it unconditionally would be a second defect wearing the
  # first one's clothes: it would change what operators already read on every
  # non-co-fire refusal, which is most of this branch's traffic. The pair below is
  # deliberately identical but for `pr_files:`.

  # The sentence operators already know, pinned as a LITERAL. Recomputing it from the
  # method under test would make the fence agree with any rewrite of that method,
  # which is the fence disarmed rather than the fence passing.
  GREEN_SUFFICIENT = "Fixing the credential is the only route — this gate advances on a GREEN CI and nothing else."
  # The gated offer AS THESE CALLS PRINT IT — they pass no `task:`, which is the
  # no-slug fallback (/tasks/builder-reads-remedy-twice). It reads this way, rather
  # than "bin/full-suite-check <task>", because the placeholder was the one token the
  # reader could not fill; a caller that HAS a slug names it instead, which the
  # deferred-cert file asserts against a rendered verdict.
  GATED_OFFER = "certify in full instead: bin/full-suite-check, run with this task's slug"
  CO_FIRE_CLAIM = "NECESSARY AND NOT SUFFICIENT"
  REMEDY_CAUSES = [:permissions, :credentials, :authentication, :rate_limit, :forbidden, nil].freeze
  REMEDY_REPO = "McRitchie-Studio/myapp"

  # END TO END THROUGH THE REAL BINARY, not through CiGate directly, and that is the
  # point: CiGate can format the derived clause perfectly while bin/dor-check never
  # hands it the list, and a unit test on the formatter would pass either way. This
  # drives the wiring.
  def test_the_co_fire_closing_names_both_refusals_in_the_review_role
    verdict, code = check(devops, ci: "unreadable", role: "review", pr_files: "unverified")
    errors = errors_of(verdict)

    assert_equal 1, code, "the co-fire must refuse:\n#{errors}"
    refute_includes errors, GREEN_SUFFICIENT,
                    "THE DEFECT: the CI half still promises that a green CI alone advances this gate, " \
                    "while the PR-read refusal below it says otherwise on the same verdict:\n#{errors}"
    assert_includes errors, CO_FIRE_CLAIM,
                    "the closing must say green is necessary and NOT sufficient here:\n#{errors}"
    assert_includes errors, "the PR's own file list going unread",
                    "the closing must NAME the other refusal, not merely hedge about it — that is the " \
                    "refused_by idiom PR #1225 established next door:\n#{errors}"
  end

  # THE FENCE (acceptance 2). Same fixture, same role, same unreadable CI — only the
  # PR read succeeds. Nothing else is refusing, so green really is sufficient and the
  # operator must read the sentence they have always read, to the byte.
  def test_the_exempt_closing_is_unchanged_when_ci_is_the_only_refusal
    verdict, code = check(devops, ci: "unreadable", role: "review", pr_files: DOC_DIFF)
    errors = errors_of(verdict)

    assert_equal 1, code, "an unreadable CI still refuses a review:\n#{errors}"
    assert_includes errors, GREEN_SUFFICIENT,
                    "with nothing else refusing, the wording operators know must survive VERBATIM — an " \
                    "over-broad fix that reworded it here is the failure this test exists to catch:\n#{errors}"
    refute_includes errors, CO_FIRE_CLAIM,
                    "nothing else is refusing this verdict, so the co-fire clause must not appear:\n#{errors}"
    refute_includes errors, "the PR's own file list going unread",
                    "the PR read SUCCEEDED here; naming it would be the misnamed-refusal defect:\n#{errors}"
  end

  # THE GATED PATH, PROVEN INERT to the new parameter across every cause. Acceptance 2
  # is about wording operators already know, and the gated route carries most of this
  # method's traffic — so the assertion is EQUALITY against the un-parameterised call,
  # not merely "still contains the offer".
  def test_unit_the_gated_route_is_untouched_by_the_derivation
    REMEDY_CAUSES.each do |cause|
      plain = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause, cert_route: true)
      loaded = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause, cert_route: true,
                                          also_refused: ["something else refused too"])

      assert_equal plain, loaded,
                   "#{cause.inspect}: the GATED route must ignore also_refused entirely — its closing is " \
                   "the cert offer, which no other refusal changes"
      assert_includes plain, GATED_OFFER, "#{cause.inspect}: the gated offer is the wording being fenced"
      refute_includes plain, CO_FIRE_CLAIM, "#{cause.inspect}: the derived clause must not leak here"
    end
  end

  # AND THE EXEMPT ROUTE WITH AN EMPTY LIST — the default every non-co-fire caller
  # takes — is byte-identical too. Stated on the METHOD as well as through the binary
  # because the binary test above can only reach one cause.
  def test_unit_an_empty_also_refused_prints_the_original_exempt_closing
    REMEDY_CAUSES.each do |cause|
      [false, nil].each do |route|
        remedy = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause, cert_route: route)

        assert remedy.end_with?(GREEN_SUFFICIENT),
               "#{cause.inspect}/#{route.inspect}: an empty also_refused must close with the original " \
               "sentence, to the byte:\n#{remedy}"
      end
    end
  end

  # ── the route fence (findings 1 and 2 of this task's review) ────────────────

  # `case` FAILS OPEN, and `:retired` made that reachable. While the route was
  # true/false/nil there was no way to misspell it; a SYMBOL can be typed wrong, and
  # `:retried` fell through the `else` and printed the GATED cert offer — on a gate
  # that retired the cert route, which is the precise defect `:retired` was added to
  # fix. The call-site registry cannot catch it: it partitions on the STRING
  # "cert_route:", so a misspelled VALUE still counts as a caller that states its
  # route and the suite stays green.
  def test_unit_a_misspelled_cert_route_raises_instead_of_printing_the_gated_offer
    error = assert_raises(ArgumentError) do
      CiStatus.unreadable_remedy(REMEDY_REPO, cause: :credentials, cert_route: :retried)
    end

    assert_includes error.message, ":retried", "the refusal must name the value it rejected"
    refute_includes error.message, GATED_OFFER,
                    "the typo must not reach the gated branch even to quote it"
  end

  # ONE FENCE, BOTH ENTRY POINTS. CiGate.unread_ci_refusal forwards this parameter on
  # one branch and BRANCHES ON IT on another (:none/:unverified) that never reaches
  # unreadable_remedy at all — so a fence living only downstream would leave that
  # branch open to the same typo.
  def test_unit_the_route_fence_is_shared_with_ci_gate
    error = assert_raises(ArgumentError) do
      CiGate.unread_ci_refusal({ state: :none }, PR_URL, "t", cert_route: :retried)
    end

    assert_includes error.message, ":retried"
  end

  # FINDING 2. bin/lib/ci_gate.rb branched on the TRUTHINESS of the route, and
  # `:retired` is truthy — so a release-grain route reaching that branch would be
  # offered `bin/full-suite-check` AND have its refusal marked cert-CLEARABLE, which
  # is the dead-remedy defect twice over. Unreachable today (both CiGate.verdict
  # callers pass literals), which is exactly when it is cheap to close.
  def test_unit_a_retired_route_neither_offers_a_cert_nor_marks_it_clearable
    %i[none unverified].each do |state|
      message, clears = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", cert_route: :retired)

      refute clears, "#{state}: a retired route must never mark a refusal cert-clearable"
      refute_includes message, "certify in full instead",
                      "#{state}: :retired is truthy — a truthiness branch offers the cert it retired:\n#{message}"
      assert_includes message, "no local cert stands in",
                      "#{state}: the denial must carry the shared CONTRACT CLAUSE:\n#{message}"
    end
  end

  # THE TWO READINGS OF ONE FACT ARE ONE STRING. The closing `refused_by` line and the
  # `also_refused:` list handed to the CI remedy describe the SAME refusal to the same
  # reader, in one verdict. Written twice they drift; bin/lib/ci_status.rb's header
  # names that exact failure ("a second copy is a second thing to forget").
  def test_unit_the_pr_read_refusal_phrase_is_written_once
    source = File.read(File.join(REPO_ROOT, "bin/dor-check"))

    assert_equal 1, source.scan("the PR's own file list going unread").size,
                 "the PR-read refusal phrase must exist ONCE in bin/dor-check, as PR_READ_REFUSAL_PHRASE — " \
                 "the refused_by line and the also_refused list must both read that constant"
  end

  # ── the WIDENED half of that closing line (/tasks/fence-the-widened-closing) ─
  #
  # WHAT WAS MISSING, and it is a fence rather than a defect. The task above fixed the
  # sufficiency claim in CiStatus.unreadable_remedy AND deliberately WIDENED to its
  # twin in bin/lib/ci_gate.rb's :none/:unverified branch — the same promise, the same
  # role, the same path, reached with a different CI state. The behaviour that shipped
  # is correct. Only the fence stopped at the file boundary: forcing
  # `no_verdict_close` to print the co-fire wording ALWAYS, and then the original
  # wording ALWAYS, left this suite green at 41 runs / 391 assertions / 0 failures,
  # while the equivalent pair on the ci_status half killed both. A derivation nothing
  # pins is a constant nobody has noticed yet, and the next reader is free to
  # "simplify" it back into the sentence PR #1225 falsified.
  #
  # SO THE PAIR IS DELIBERATE, exactly as it is next door: the two tests below differ
  # by ONE input — whether anything else is refusing this verdict — because that is
  # the only input the sentence is allowed to depend on. Rewording it unconditionally
  # would change what operators read on every NON-co-fire refusal, which is most of
  # this branch's traffic, and that is a second defect wearing the first one's clothes.
  #
  # AND THE PAIR IS RUN TWICE, at two grains, for the reason the ci_status half
  # learned the hard way: CiGate can format the derived clause perfectly while
  # bin/dor-check never hands it the list. The unit pair pins the FORMATTER (and is
  # what the two mutations above go red on); the binary pair pins the WIRING.

  # The sentence operators already know, pinned as a LITERAL for the same reason
  # GREEN_SUFFICIENT is: recomputing it from the method under test would make the
  # fence agree with any rewrite of that method — the fence disarmed, not passing.
  NO_VERDICT_GREEN_SUFFICIENT = "Green is the only thing that advances it."
  # The two states that reach the closing line. :unreadable is the THIRD member of
  # CI_NO_VERDICT_STATES and is deliberately absent: it takes the other branch, which
  # delegates to CiStatus.unreadable_remedy and is fenced by the pair above.
  NO_VERDICT_CLOSING_STATES = %i[none unverified].freeze
  # The noun phrase bin/dor-check actually hands down — its PR_READ_REFUSAL_PHRASE,
  # spelled here in full so the co-fire assertion reads the whole sentence the
  # operator does, including the words the closing clause has to attach to.
  PR_READ_NOUN_PHRASE = "the PR's own file list going unread, so the doc-only exemption was never proven " \
                        "against the artifact this gate judges"
  # THE CO-FIRE CLOSES THE SAME WAY IN BOTH TWINS, and it must be an INDEPENDENT
  # clause. ci_gate.rb's copy ended "..., which green does not clear" — and the list it
  # interpolates is a NOUN PHRASE ending in "the artifact this gate judges", so the
  # relative pronoun attached to the ARTIFACT and the sentence said green does not
  # clear the artifact. Its ci_status.rb twin was already right. One meaning, one
  # spelling, and the tail is what makes that checkable.
  CO_FIRE_TAIL = "and no CI result clears that."

  # [unit] MUTATION 1 DIES HERE. Force `no_verdict_close` to the ORIGINAL always and
  # this test goes red: the co-fire's closing must name what else is refusing.
  def test_unit_the_no_verdict_co_fire_closing_names_both_refusals
    NO_VERDICT_CLOSING_STATES.each do |state|
      message, clears = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", cert_route: false,
                                                                                also_refused: [PR_READ_NOUN_PHRASE])

      refute clears, "#{state}: the exempt route never marks a refusal cert-clearable"
      refute_includes message, NO_VERDICT_GREEN_SUFFICIENT,
                      "#{state}: THE DEFECT — the CI half still promises a green CI alone advances this " \
                      "gate, while the PR-read refusal on the same verdict says otherwise:\n#{message}"
      assert_includes message, CO_FIRE_CLAIM,
                      "#{state}: the closing must say green is necessary and NOT sufficient here:\n#{message}"
      assert_includes message, PR_READ_NOUN_PHRASE,
                      "#{state}: the closing must NAME the other refusal, not merely hedge about it — that " \
                      "is the refused_by idiom, reused rather than reinvented:\n#{message}"
      assert message.end_with?(CO_FIRE_TAIL),
             "#{state}: the closing must end with the INDEPENDENT clause its twin uses — a relative " \
             "pronoun here attaches to the noun phrase's last words, not to the refusal:\n#{message}"
    end
  end

  # AND THE TWIN ENDS THE SAME WAY. The two co-fire closings describe one fact to one
  # reader, reached with a different CI state; written twice they drift, which is the
  # failure bin/lib/ci_status.rb's header names in so many words.
  def test_unit_both_co_fire_closings_end_with_the_same_independent_clause
    gate, = CiGate.unread_ci_refusal({ state: :none }, PR_URL, "t", cert_route: false,
                                                                    also_refused: [PR_READ_NOUN_PHRASE])
    status = CiStatus.unreadable_remedy(REMEDY_REPO, cause: :credentials, cert_route: false,
                                                     also_refused: [PR_READ_NOUN_PHRASE])

    assert gate.end_with?(CO_FIRE_TAIL), "ci_gate.rb's co-fire closing:\n#{gate}"
    assert status.end_with?(CO_FIRE_TAIL), "ci_status.rb's co-fire closing:\n#{status}"
  end

  # [unit] MUTATION 2 DIES HERE. Force `no_verdict_close` to the CO-FIRE wording always
  # and this test goes red — including on the empty list, where the join renders a
  # refusal by nobody. Nothing else is refusing, so green really is sufficient and the
  # operator must read the sentence they have always read, TO THE BYTE.
  def test_unit_an_empty_also_refused_prints_the_original_no_verdict_closing
    NO_VERDICT_CLOSING_STATES.each do |state|
      [false, nil].each do |route|
        message, = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", cert_route: route)

        assert message.end_with?(NO_VERDICT_GREEN_SUFFICIENT),
               "#{state}/#{route.inspect}: with nothing else refusing, the wording operators know must " \
               "survive VERBATIM — an over-broad fix that reworded it here is what this catches:\n#{message}"
        refute_includes message, CO_FIRE_CLAIM,
                        "#{state}/#{route.inspect}: nothing is refusing this verdict besides CI:\n#{message}"
      end
    end
  end

  # [unit] AND THE GATED ROUTE IS INERT TO THE LIST, asserted as EQUALITY rather than
  # "still contains the offer" — the gated call carries most of this branch's traffic,
  # and `also_refused` must not leak a word into it. Its closing is the cert offer,
  # which no other refusal changes.
  def test_unit_the_gated_no_verdict_route_is_untouched_by_the_derivation
    NO_VERDICT_CLOSING_STATES.each do |state|
      plain, plain_clears = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", cert_route: true)
      loaded, loaded_clears = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", cert_route: true,
                                                                                      also_refused: [PR_READ_NOUN_PHRASE])

      assert_equal plain, loaded, "#{state}: the GATED route must ignore also_refused entirely"
      assert_equal plain_clears, loaded_clears, "#{state}: nor may it move the cert_clears flag"
      assert_includes plain, "certify in full instead", "#{state}: the gated offer is the wording being fenced"
      refute_includes plain, CO_FIRE_CLAIM, "#{state}: the derived clause must not leak here"
    end
  end

  # [integration] THE WIRING, END TO END THROUGH THE REAL BINARY. The unit pair above
  # passes happily while bin/dor-check never builds `exempt_also_refused` or never
  # forwards it — the exact failure the ci_status half proved lethal as its mutation B.
  # A :none CI plus an unreadable PR file list is the co-fire reaching THIS branch.
  def test_the_no_verdict_co_fire_closing_names_both_refusals_in_the_review_role
    verdict, code = check(devops, ci: "none", role: "review", pr_files: "unverified")
    errors = errors_of(verdict)

    assert_equal 1, code, "the co-fire must refuse:\n#{errors}"
    refute_includes errors, NO_VERDICT_GREEN_SUFFICIENT,
                    "THE DEFECT: the CI half still promises that a green CI alone advances this gate, " \
                    "while the PR-read refusal below it says otherwise on the same verdict:\n#{errors}"
    assert_includes errors, CO_FIRE_CLAIM,
                    "the closing must say green is necessary and NOT sufficient here:\n#{errors}"
    assert_includes errors, "the PR's own file list going unread",
                    "the closing must NAME the other refusal — the list must actually reach the " \
                    "formatter, which is what this tier is here to prove:\n#{errors}"
  end

  # [integration] THE FENCE AT THE SAME GRAIN. Same fixture, same role, same no-verdict
  # CI — only the PR read succeeds. Nothing else is refusing, so the sentence operators
  # already know must come back out of the binary unchanged.
  def test_the_no_verdict_closing_is_unchanged_when_ci_is_the_only_refusal
    verdict, code = check(devops, ci: "none", role: "review", pr_files: DOC_DIFF)
    errors = errors_of(verdict)

    assert_equal 1, code, "a no-verdict CI still refuses a review:\n#{errors}"
    assert_includes errors, NO_VERDICT_GREEN_SUFFICIENT,
                    "with nothing else refusing, the wording operators know must survive VERBATIM:\n#{errors}"
    refute_includes errors, CO_FIRE_CLAIM,
                    "nothing else is refusing this verdict, so the co-fire clause must not appear:\n#{errors}"
    refute_includes errors, "the PR's own file list going unread",
                    "the PR read SUCCEEDED here; naming it would be the misnamed-refusal defect:\n#{errors}"
  end

  # [unit] THE SECONDARY SITE, and why it is a bare literal rather than a pair. The
  # unclassified-state branch borrowed the same words to justify its refusal — "the
  # review gate-zero advances on a GREEN CI and nothing else" — and there the claim was
  # doing NECESSITY work only: this state is not green, therefore refuse. That argument
  # never needed sufficiency, so the sentence now says what the allow-list actually
  # enforces. The branch consults nothing, so there is no derivation to fence: an
  # unconditional string is pinned by pinning it, and the retired claim is refuted by
  # name so it cannot drift back in as a "simplification".
  #
  # THE FIRST CORRECTION WAS NOT ENOUGH. It landed as "GREEN is the only CI state that
  # advances a review", which is measurably false: driven through bin/dor-check
  # --gate-role review with a FULL cert, :none, :unverified AND :unreadable each reach
  # ready=true exit=0. THREE non-green states advance a review. Green is alone in
  # PASSING, not in advancing — a cert can waive a refusal, so they are different
  # predicates — and the sentence now borrows the word ci_gate.rb's own comment was
  # already using. BOTH retired spellings are refuted below, because a correction that
  # drops its predecessor's name is how the predecessor comes back.
  def test_unit_the_unclassified_refusal_argues_from_necessity_not_sufficiency
    message, clears = CiGate.unread_ci_refusal({ state: :surprise }, PR_URL, "t")

    refute clears, "an unclassified state is not the no-verdict family; no cert clears it"
    assert_includes message, "GREEN is this gate's sole PASSING CI state",
                    "the refusal must argue from what the allow-list enforces:\n#{message}"
    refute_includes message, "advances on a GREEN CI and nothing else",
                    "THE FIRST RETIRED CLAIM: green advances the CI allow-list, not the gate — the shape, tier " \
                    "and PR-read gates all refuse on a fully green CI:\n#{message}"
    refute_includes message, "the only CI state that advances a review",
                    "THE SECOND RETIRED CLAIM: three non-green states advance a review. :none, :unverified " \
                    "and :unreadable each reach ready=true exit=0 when the task carries a FULL cert, so " \
                    "GREEN is alone in PASSING and not in advancing:\n#{message}"
  end

  # ── the supervisor's own copy of the sentence ───────────────────────────────
  #
  # A FOURTH COPY, in a different binary, and the sharpest of the four because of
  # WHERE it prints. bin/pr-review's `cert_caveat` closed "green is the only thing that
  # advances it", and it is interpolated into exactly two lines: the :unreadable branch
  # and the :unverified `else`. Those are the co-fire's OWN TRIGGERS — one stale App
  # token refuses the check read and the PR file read together — so in the very
  # incident this family is about, the supervisor told a reviewer green was SUFFICIENT
  # one screen before their gate-zero told them it was NECESSARY AND NOT SUFFICIENT.
  # It also contradicted docs/agents/agents/carl/sops/pr-review-primary.md, which had
  # already been corrected.
  #
  # WHY THIS IS A SOURCE TEST. `cert_caveat` is a local inside a method that spawns
  # real reviewer subprocesses; there is no value seam to call. bin/pr-review's other
  # prose invariants are pinned the same way (test/lib/pr_review_zap_safety_test.rb),
  # and the property here is genuinely structural: the supervisor and the gate must
  # tell ONE story, in ONE spelling, at BOTH print sites.
  SUPERVISOR_GREEN_SUFFICIENT = "green is the only thing that advances it"

  def pr_review_source = File.read(File.join(REPO_ROOT, "bin/pr-review"))

  # THE SAME FILE WITH ITS COMMENT-ONLY LINES REMOVED — what the script can actually
  # PRINT. The header above quotes the retired sentence on purpose (a correction that
  # deletes its own provenance is how a claim comes back), and a whole-file scan cannot
  # tell that quotation from a live promise: it failed on the explanation of the fix.
  #
  # HEREDOC BODIES ARE NOT COMMENTS, and skipping that distinction would have put the
  # hole back where it hurts most. bin/pr-review hands its reviewers PROMPT/TEXT
  # heredocs — PROSE, which is this whole family's subject — and a markdown heading
  # inside one begins with `#`. A flat "drop every line starting with #" would let the
  # retired claim live on, invisibly, in the one place the supervisor's words reach a
  # reviewer most directly. So heredoc bodies are tracked and kept. `#{` is kept too:
  # an interpolation is code.
  #
  # Trailing comments are deliberately left in, so a claim parked at the end of a code
  # line still trips this. test_unit_the_supervisor_stops_promising... is proven to
  # bite by mutation: the claim reinstated on a code line fails it.
  def pr_review_printable = printable_ruby(pr_review_source)

  def printable_ruby(source)
    heredoc = nil
    source.lines.reject { |line|
      if heredoc
        heredoc = nil if line.strip == heredoc
        false
      elsif (open = line[/<<[~-]?["']?([A-Z_]+)["']?/, 1])
        heredoc = open
        false
      else
        line.lstrip.start_with?("#") && !line.lstrip.start_with?("\#{")
      end
    }.join
  end

  # THE SAME PREDICATE WITH THE HEREDOC BRANCH DISARMED — a flat comment-strip. It is
  # the control for the control: differencing it against printable_ruby says what the
  # heredoc branch is load-bearing for in a given file, and it re-implements nothing
  # else.
  def flat_strip(source)
    source.lines.reject { |line| line.lstrip.start_with?("#") && !line.lstrip.start_with?("\#{") }.join
  end

  # The lines the heredoc branch KEEPS and a flat strip drops — the branch's whole
  # observable effect on a file. flat_strip drops a superset of what printable_ruby
  # drops and preserves order, so its output is a subsequence of the other's and one
  # greedy walk names the difference. Returned as LINES, not as a diff of two whole
  # files: a failure here must print the offending heredoc line, not bin/pr-review.
  def heredoc_only_lines(source)
    flat = flat_strip(source).lines
    cursor = 0
    printable_ruby(source).lines.reject do |line|
      keep = cursor < flat.size && flat[cursor] == line
      cursor += 1 if keep
      keep
    end
  end

  # THE STRIPPER'S OWN CONTROL, because a scan that reads nothing passes everything.
  # bin/pr-review DOES carry heredoc lines that begin with `#` — the reviewer PROMPT
  # heredoc interpolates its sections — but every one of them is a `#{...}`, which the
  # interpolation exemption keeps on its own. So the heredoc branch decides none of
  # them, and driving this control against the real file would exercise nothing. That
  # is the reason, and it is CHECKED rather than asserted in prose
  # (/tasks/gate-prose-overclaims-again): the header used to claim the file carried no
  # such line at all, which was flatly false while the conclusion drawn from it was
  # right — a comment about prose drifting from behaviour, drifting from behaviour.
  #
  # ITS OWN TEST, NOT A PRELUDE TO THE FIXTURE'S (/tasks/exempt-path-claim-unqualified).
  # These two source scans and the four fixture assertions below used to share one
  # method, with the scans FIRST — so the day this alarm fired, Minitest stopped at it
  # and the four checks it was standing in front of never executed. A firing alarm
  # would have silently retired the very assertions that say what the stripper is FOR,
  # and the run would have reported one failure where there might have been five. Two
  # methods, not a reordering: order only chooses which half goes blind, and split
  # leaves neither able to suppress the other.
  def test_unit_the_printable_stripper_control_reads_the_real_file
    refute_equal pr_review_source, flat_strip(pr_review_source),
                 "CONTROL: the scan must have read a real file — bin/pr-review carries full-line comments, " \
                 "so a strip that removed nothing removed nothing from nothing"
    assert_empty heredoc_only_lines(pr_review_source).map(&:strip),
                 "the heredoc branch now CHANGES bin/pr-review's printable source: the lines above begin " \
                 "with `#` inside a heredoc and are not `\#{...}` interpolations, so the branch — not the " \
                 "interpolation exemption — is what keeps them. The header above is stale; drive this " \
                 "control against the real file, and correct the header before re-pinning it"
  end

  # The fixture puts one claim in each of the four positions and states which two must
  # survive. It shares nothing with the control above but the predicate under test, and
  # that is deliberate — see that method's header.
  def test_unit_the_printable_stripper_keeps_prose_and_drops_comments
    fixture = <<~RUBY
      # CLAIM_IN_A_COMMENT — provenance, must be dropped
      note = "CLAIM_IN_A_STRING"
      prompt = <<~PROMPT
        # CLAIM_IN_A_HEREDOC_HEADING
        body
      PROMPT
      value = "x" # CLAIM_IN_A_TRAILING_COMMENT
    RUBY
    printable = printable_ruby(fixture)

    refute_includes printable, "CLAIM_IN_A_COMMENT", "a full-line Ruby comment is not printable"
    assert_includes printable, "CLAIM_IN_A_STRING", "a string literal is printable"
    assert_includes printable, "CLAIM_IN_A_HEREDOC_HEADING",
                    "a markdown heading inside a PROMPT heredoc is PROSE HANDED TO A REVIEWER — the one " \
                    "place this claim would do the most damage, and a flat comment-strip hides it"
    assert_includes printable, "CLAIM_IN_A_TRAILING_COMMENT",
                    "a claim parked after code on a live line must still trip the guard"
  end

  # The caveat literal itself — from the assignment to its `else`, so the assertions
  # below describe the string that is PRINTED and not a comment that describes it.
  def cert_caveat_literal
    body = pr_review_source[/cert_caveat = if maybe_exempt\n(.*?)\n\s*else\n/m, 1]
    refute_nil body, "bin/pr-review must still build cert_caveat from an exempt-kind branch"
    body
  end

  # THE SAME LITERAL AS THE REVIEWER READS IT — the Ruby string-continuation seams
  # (`" \` + newline + indent + `"`) closed up, so the sentence is one run of text. An
  # assertion about a CLAUSE has to span those seams or it grades the source layout:
  # rewrapping the same words across different lines would move a clause boundary and
  # red-seal a caveat nobody changed. Everything else is left alone, interpolations
  # included — this closes a seam, it does not evaluate the string.
  def cert_caveat_text = cert_caveat_literal.gsub(/"\s*\\\n\s*"/, "")

  def test_unit_the_supervisor_stops_promising_a_green_ci_advances_the_exempt_path
    assert_includes cert_caveat_literal, CO_FIRE_CLAIM,
                    "the supervisor must brief the reviewer with the SAME claim their gate-zero prints — " \
                    "green is necessary here and not sufficient:\n#{cert_caveat_literal}"
    refute_includes pr_review_printable, SUPERVISOR_GREEN_SUFFICIENT,
                    "bin/pr-review still promises a green CI carries the exempt path. It prints this on the " \
                    "co-fire's own trigger, so the supervisor contradicts the gate it is briefing for"
  end

  # The caveat must still name what a green CI would NOT clear — the same other half
  # the gate's own closing names. A correction that only DELETED the false clause would
  # pass the test above and leave the reviewer with no reason for the refusal they meet.
  def test_unit_the_supervisor_names_the_refusal_a_green_ci_would_not_clear
    assert_includes cert_caveat_literal, "unread PR file list",
                    "the caveat must name the other refusal on this path, not merely hedge:\n#{cert_caveat_literal}"
  end

  # ONE LITERAL, TWO SITES, TWO CAUSES. The caveat closed "one stale token refuses both
  # reads" — a credential story, and it is interpolated at BOTH print sites. It is true
  # at the :unreadable branch, where GitHub refused the credential. It is FALSE at the
  # :unverified `else`: bin/lib/ci_status.rb defines :unverified as a gh/network fault
  # and bin/dor-check's own alert calls that read "NOT a credential refusal". Naming one
  # site's cause in a literal both sites print sends half the readers hunting a token
  # while `gh` is simply down, so the closing must name the CLASS the two share.
  #
  # THE FIRST VERSION OF THIS GUARD WAS DOCUMENTARY, NOT BEHAVIOURAL
  # (/tasks/exempt-path-claim-unqualified). It pinned three SUBSTRINGS, so it graded a
  # spelling rather than the claim — and one reword walks straight through all three.
  # Measured: rewriting the closing as "a refused token, NOT a `gh`/network failure"
  # REINSTATES the retired credential story (it now asserts one cause and DENIES the
  # other, which is worse than the sentence this family retired) and the pin stayed
  # green at 1 run / 12 assertions. A guard the reinstatement passes is a comment with
  # a `def` in front of it.
  #
  # SO ASSERT THE SHAPE OF THE CLAIM. The property is that the two causes are offered
  # as ALTERNATIVES — one fault, either of two origins, neither excluded — because
  # that is the only reading true at both print sites. The clause is extracted (from
  # "hides both reads" to the next `;`) and asked four things: it names the credential
  # cause, it names the transport cause, it joins them disjunctively, and it does not
  # EXCLUDE either. Scoping the exclusion check to that clause is what makes it usable
  # at all — the caveat's own "NECESSARY AND NOT SUFFICIENT" sits two clauses earlier,
  # and a whole-literal negation scan would red-seal the correct sentence.
  #
  # WHAT IT STILL CANNOT SEE, stated rather than papered over. This is a source scan of
  # a string literal; it reads syntax, not meaning. A reinstatement that keeps the
  # disjunction and then leans on it in prose the clause does not contain — "…, or a
  # `gh`/network failure; usually the token" — passes, because the closing it grades
  # ends at the semicolon. Closing that would mean grading the whole caveat for
  # emphasis, which has no fixture and no seam at this grain: `cert_caveat` is a local
  # in a method that spawns real reviewer subprocesses (see pr_review_source's header),
  # so there is no value to call and nothing to drive. The guard is therefore sound
  # against DROPPING or NEGATING a cause — the two shapes the retired claim actually
  # wore — and blind to re-weighting one. That boundary is the file's grain, not an
  # oversight, and it is written down so the next reader does not mistake the pin for
  # a proof.
  CO_FIRE_CAUSE_CREDENTIAL = /token/i
  CO_FIRE_CAUSE_TRANSPORT = %r{`gh`/network}
  CO_FIRE_DISJUNCTION = /\bor\b/i
  # Excluding a cause instead of offering it — the reinstatement's whole move.
  CO_FIRE_EXCLUSION = /\bnot\b|\bnever\b|\brather than\b|\binstead of\b|\bn't\b/i

  # The co-fire's CAUSE CLAUSE, as the reviewer reads it: "hides both reads" up to the
  # `;` that ends the thought. Read off cert_caveat_text (seams removed) so a reflow of
  # the Ruby continuation lines cannot change what these assertions match.
  def cert_caveat_cause_clause
    clause = cert_caveat_text[/hides both reads(.*?);/m, 1]
    refute_nil clause, "the caveat must still close with a co-fire clause ending in `;`:\n#{cert_caveat_text}"
    clause
  end

  def test_unit_the_supervisor_caveat_names_a_cause_true_at_both_print_sites
    clause = cert_caveat_cause_clause

    refute_includes cert_caveat_text, "stale token refuses both reads",
                    "THE RETIRED CLAIM, verbatim: this literal also prints on the :unverified `else`, which " \
                    "is a TRANSPORT fault — bin/dor-check calls it \"NOT a credential refusal\":\n" \
                    "#{cert_caveat_text}"
    assert_includes cert_caveat_text, "fault hides both reads",
                    "the caveat must still name the co-fire — the two reads fail together:\n#{cert_caveat_text}"

    assert_match CO_FIRE_CAUSE_CREDENTIAL, clause,
                 "the co-fire clause must name the CREDENTIAL cause, which is the :unreadable site's:\n#{clause}"
    assert_match CO_FIRE_CAUSE_TRANSPORT, clause,
                 "and the NON-credential cause, which is the one the :unverified site actually meets:\n#{clause}"
    # EXCLUSION BEFORE DISJUNCTION, and the order is the message. A reinstatement
    # trips both — it swaps the "or" for a "NOT" — and Minitest prints only the first,
    # so the first must be the one that names the DEFECT. Reversed, the operator who
    # reworded the closing is told their grammar is wrong.
    refute_match CO_FIRE_EXCLUSION, clause,
                 "THE RETIRED CLAIM, REWORDED: this clause EXCLUDES one of the two causes. Both are live — " \
                 "the credential story at the :unreadable branch, the transport story at the :unverified " \
                 "`else` — so a closing that denies either is wrong for half its traffic, which is the " \
                 "defect this guard exists to catch and not a stronger version of it:\n#{clause}"
    assert_match CO_FIRE_DISJUNCTION, clause,
                 "the two causes must be offered as ALTERNATIVES — one fault, either origin. A clause that " \
                 "names both without joining them is asserting, not offering:\n#{clause}"
  end

  # THE WIRING, at this file's only available grain: the caveat is INTERPOLATED at both
  # print sites. Dropping either one silently restores the old briefing for half the
  # traffic — the :unverified `else` is exactly where a flaky read lands.
  def test_unit_the_supervisor_caveat_reaches_both_of_its_print_sites
    assert_equal 2, pr_review_source.scan("\#{cert_caveat}").size,
                 "cert_caveat must be interpolated into BOTH the :unreadable branch and the :unverified " \
                 "else — those are the two places the exempt caveat is briefed"
  end

  # ONE STORY ACROSS THE TOOL AND THE SOP. pr-review-primary.md corrected this claim
  # first (2026-09-05) and the tool contradicted it for a day. Keep them pinned to each
  # other so the next correction cannot land in only one of them.
  def test_unit_the_primary_sop_and_the_supervisor_agree_that_green_is_not_enough
    sop = File.read(File.join(REPO_ROOT, "docs/agents/agents/carl/sops/pr-review-primary.md"))

    assert_includes sop, "Expect a refusal that a GREEN CI does not clear",
                    "the primary SOP must keep its correction — the supervisor's caveat now matches it"
    refute_includes sop, SUPERVISOR_GREEN_SUFFICIENT,
                    "the SOP must not re-acquire the claim the tool just dropped"
  end
end

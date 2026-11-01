# frozen_string_literal: true

# The EXEMPT (doc-only) path must read CI. A bare `exit 0` must not sit above the CI
# allow-list and the gate-verdict emit. `dor_review` reading null means the gate did not run;
# test_the_exempt_verdict_records_a_gate_attempt_in_both_directions pins that only observable.
# WHAT MUST *NOT* CHANGE: only the shape/TEST-TIER gate is waived on a prose diff. CI GRADES
# PROSE, so "ships no behavior" is not "cannot fail CI". Relocating the CI block above the
# exit passes every other test here and fails
# test_the_tier_gate_is_still_waived_on_a_green_exempt_diff and its control.
# History: task gate-zero-skips-docs-ci.
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

  # Runs dor-check against an in-memory task, returns [parsed_json, exitcode]. STDOUT only:
  # under `bin/rails test` the child emits rubygems warnings on STDERR, which would corrupt the
  # --json parse.
  # `pr_files:` defaults to the list the diff is injected from (the PR read succeeded). Pass
  # "unreadable"/"unverified" for the FAILED-read worlds. It is separate from `changed:` for the
  # reason refusal()'s header states: a fixture that can only vary them together cannot express
  # the failure it pins.
  # History: task gate-zero-skips-docs-ci.
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

  # ── [unit] CiGate: the decision table both paths share ──
  # Pure: no subprocess, no ENV, no board. The states the exempt path must refuse are asserted
  # here directly, not inferred from a verdict's prose.
  # READ "ADVANCES" AT THIS GRAIN: CiGate returns no refusal, and green is alone in that IN BOTH
  # ROLES. No local cert stands in for a no-verdict state. The one role split left is :pending:
  # a WAIT for the builder (still a refusal, worded as waiting) and a refusal for review.
  # History: task dor-reads-settled-ci-verdict.

  def test_unit_green_is_the_only_state_that_advances
    [true, false].each do |review_role|
      error = CiGate.verdict({ state: :green }, review_role: review_role, pr_url: PR_URL, slug: "t")
      assert_nil error, "green must advance (review_role: #{review_role})"
    end
  end

  def test_unit_every_non_green_state_refuses_in_both_roles
    %i[red pending conflicted ci_less closed merged none unreadable unverified no_pr].each do |state|
      [true, false].each do |review_role|
        error = CiGate.verdict({ state: state }, review_role: review_role, pr_url: PR_URL, slug: "t")
        refute_nil error, "#{state} must refuse (review_role: #{review_role})"
        refute_includes error, "certify in full", "#{state}: no refusal offers a cert"
      end
    end
  end

  # THE ALLOW-LIST PROPERTY, not a longer deny-list: a state this gate has never
  # heard of refuses too. Testing only the real tokens cannot tell an allow-list
  # from a deny-list, and the difference is a live false pass.
  def test_unit_an_unclassified_state_refuses_rather_than_falling_through
    [true, false].each do |review_role|
      error = CiGate.verdict({ state: :teal }, review_role: review_role, pr_url: PR_URL, slug: "t")
      assert_includes error.to_s, "does not classify", "review_role: #{review_role}"
    end
  end

  def test_unit_a_blank_pr_url_refuses_in_both_roles
    review = CiGate.verdict({ state: :no_pr }, review_role: true, pr_url: "", slug: "t")
    assert_includes review.to_s, "BLANK"
    assert_includes review.to_s, "nothing to merge", "review's job is to merge a PR"

    builder = CiGate.verdict({ state: :no_pr }, review_role: false, pr_url: "", slug: "t")
    assert_includes builder.to_s, "BLANK"
    assert_includes builder.to_s, "open the PR", "the builder's move is to open one"
  end

  # Guard catalog row 1.10: bin/submit calls the gate only after its CI wait settles,
  # so no builder-side WAIT survives. Pending and none read one refusal in both roles.
  def test_unit_pending_and_none_refuse_alike_in_both_roles
    %i[pending none].each do |state|
      builder = CiGate.verdict({ state: state, pending: ["ci"] }, review_role: false, pr_url: PR_URL, slug: "t")
      review = CiGate.verdict({ state: state, pending: ["ci"] }, review_role: true, pr_url: PR_URL, slug: "t")

      assert_equal review, builder, "#{state}: one refusal for both roles"
      refute_includes builder.to_s, "WAITING"
    end
    refute CiGate.respond_to?(:waiting?), "the builder-side wait predicate is gone"
  end

  def test_unit_gate_row_names_ci_as_the_failing_sop_when_ci_is_why_it_failed
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
    # THE REFUSED GREEN. The stale-green refusal fires only when ci[:state] == :green,
    # so this vector is the one that decides whether `review_refused` is wired to
    # anything at all on that path. It graded "pass" until 2026-09-07: the review
    # refused while the gates card recorded CI as passing.
    assert_equal "fail", CiGate.gate_row({ state: :green }, review_role: true, review_refused: true)
    # …and the builder-side pending row: a WAIT is in-flight whichever flag the caller
    # passes, because the row is about the CI STATE and that state is still coming.
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :red }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: true)
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    # THIS ASSERTION PINNED A DEFECT UNTIL 2026-09-08 (/tasks/gate-logs-auth-as-red).
    # :unreadable means GitHub REFUSED the read — the gate saw no verdict at all — and
    # recording it as "fail" wrote a red-CI bounce that never happened into the task's
    # PERMANENT gate history. Installation tokens expire ~hourly by design here, so
    # every gate run straddling an expiry produced one. It now names the state it is
    # actually in; a genuinely red CI (asserted three lines up) still says "fail", so
    # the record keeps the two causes apart. Its own coverage lives in
    # test/lib/gate_record_unreadable_ci_test.rb, which reads the PERSISTED row.
    assert_equal "unreadable", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: true)
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

  # THE NEIGHBOURS, not just red. The documented allow-list refuses each of these, exempt or
  # not. THE RECORDED ROW IS ASSERTED PER-STATE, NOT AS ONE FLAT "fail": the durable row
  # outlives the refusal text and must say which non-answer it got. CiGate::CI_NO_VERDICT_STATES
  # each carry their OWN word, 1:1 with the CI state; as "fail" they record a red-CI bounce that
  # never happened. "fail" stays for states that settled negative: a red CI, a conflict, a
  # closed target, and an unclassified state an allow-list must refuse by default.
  # History: task refused-review-records-fail.
  def test_pending_unreadable_and_unclassified_ci_all_refuse_an_exempt_review
    {
      "pending" => ["still RUNNING", "fail"],
      "unreadable" => ["UNREADABLE", "unreadable"],
      "unverified" => ["no verdict yet", "unverified"],
      "none" => ["no verdict yet", "no_checks"],
      "conflicted" => ["gate-zero", "fail"],
      "closed" => ["not an OPEN review target", "fail"],
      "state:teal" => ["does not classify", "fail"]
    }.each do |injected, (expected, recorded)|
      verdict, code = check(devops, ci: injected)

      assert_equal 1, code, "#{injected} must refuse"
      assert_includes errors_of(verdict), expected
      assert_equal recorded, verdict["ci_gate_result"],
                   "#{injected} must record CI as the reason, under the name of the state it was actually in"
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
  # The builder's submit-side run refuses a pending CI (bin/submit never calls it on
  # one, row 1.10), a missing PR (there is no verdict to read), and a RED CI.
  def test_the_builder_role_refuses_pending_and_the_rest
    pending, code = check(devops, ci: "pending", role: "builder")
    assert_equal 1, code, "submit-side pending is not ready"
    refute pending.key?("ci_waiting"), "the builder-side wait is gone"
    assert_includes errors_of(pending), "still RUNNING"

    no_pr, no_pr_code = check(devops("pr_url" => ""), role: "builder")
    assert_equal 1, no_pr_code, "with no PR there is no CI verdict to read"
    assert_includes errors_of(no_pr), "devops.pr_url is BLANK"

    red, red_code = check(devops, ci: "red", role: "builder")
    assert_equal 1, red_code, "a RED CI blocks in BOTH roles"
    assert_includes errors_of(red), "GitHub CI is RED"
  end

  # ── the exempt path must CONFIRM that it IS exempt ──
  # The reviewer's checkout is NOT the task's tree, so a doc-only exemption must not be earned
  # there while the PR goes unread: a failed PR-file read is an ERROR for review, a SUGGESTION
  # for the builder. BOTH FAILED-READ STATES: a review `:unreadable` is caught upstream in
  # resolve_branch_diff (diff_source :pr_unreadable), but `:unverified` (gh missing, a 404, a
  # transport error, an API outage) is a failed read too and can reach the grant through the
  # local tree. Sister defect: /tasks/gate-zero-skips-docs-ci.
  # History: task exempt-path-trusts-local-tree.
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

  # THE RECEIPT SURVIVES THE PROMOTION. `pr_read` is how a monitor asks "was the PR actually
  # read?" of a verdict later. It is keyed off the refusal itself, not the SUGGESTION list, or
  # it blanks in the role where it matters most.
  # THE BUILD GATE STAYS LENIENT, review role or not. Removing `gate != "build"` from the role
  # split leaves every other test in this file green, so this test holds that clause. The build
  # gate resolves no diff and must not shell `gh`, so a failed PR read there is evidence of
  # nothing. Line 2356's gated-path twin carries the same clause.
  # History: task exempt-path-trusts-local-tree.
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

  # ══ NO VERDICT OFFERS A CERT, AND A RECORDED CERT CHANGES NOTHING ════════════
  # The suite evidence is the PR's settled green CI, on every path and in every role, and the
  # fingerprint receipts are not read (since /tasks/dor-reads-settled-ci-verdict). So every
  # no-verdict refusal DENIES a cert, offers none, and a recorded full cert leaves the refusal
  # byte-identical. That byte-identity is the proof that the denial is accurate.
  # History: task exempt-refusal-prints-dead-remedy.

  # THE CONTRACT CLAUSES. Each is spelled ONCE in the source (bin/lib/ci_gate.rb and
  # bin/lib/ci_status.rb) and read here to classify a refusal. They are deliberately
  # the wording an operator acts on, not an internal token.
  OFFERS_CERT = "certify in full instead"
  DENIES_CERT = "no local cert stands in"

  # The GATED twin of `devops` — a code diff under a shaped bug.
  GATED_CODE_DIFF = "app/models/thing.rb"

  # What the retired bin/full-suite-check recorded: a full cert at a fingerprint. Whatever the
  # hash, the gate must not read it.
  FULL_CERT_RECEIPTS = ["[full-suite@#{'a' * 40}] bin/rails test (11004 runs, 0 failures)",
                        "[rubocop@#{'a' * 40}] bin/rubocop (clean)"].freeze

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

  # Runs the REAL binary on either path, returns [stdout, exitcode]. `pr_files:` is a
  # SEPARATE dimension from `ci:`: one stale App token refuses the PR file list and
  # the check read together, so :unreadable co-fires on both, and a fixture that
  # could only vary them together could not express the normal shape of the failure
  # this section is about. DOR_CHECK_CHANGED_FILES stays set: it is what keeps an
  # unreadable PR read on the EXEMPT branch.
  def refusal(path, ci:, pr_files: :readable, receipts: [])
    payload, changed = path == :exempt ? [devops, DOC_DIFF] : [gated_devops, GATED_CODE_DIFF]
    payload = payload.merge("checks_run" => Array(payload["checks_run"]) + receipts)
    injected_pr_files = pr_files == :readable ? changed : "unreadable"
    Dir.mktmpdir do |dir|
      file = File.join(dir, "task.json")
      File.write(file, JSON.generate("slug" => "remedy-task", "title" => "R",
                                     "metadata" => { "devops" => payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => injected_pr_files,
        "DOR_CHECK_CI_STATUS" => ci
      })
      out = IO.popen(env, "#{BIN} remedy-task --file #{file} --gate-role review 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  # THE PROPERTY, over both paths and both PR-read worlds. The gated×unreadable cell
  # used to be excluded because its PR-read half was an error no cert cleared while
  # its CI half offered one — a dead remedy. With no offer anywhere, the cell is
  # ordinary and the property covers it.
  def test_every_no_verdict_refusal_denies_a_cert_and_a_recorded_cert_changes_nothing
    [%i[exempt readable], %i[exempt unreadable], %i[gated readable], %i[gated unreadable]].each do |path, pr_files|
      %w[none unverified unreadable].each do |state|
        label = "#{path}/#{state}/pr_files:#{pr_files}"
        refused, code = refusal(path, ci: state, pr_files: pr_files)
        assert_equal 1, code, "#{label} must refuse:\n#{refused}"
        assert_includes refused, DENIES_CERT, "#{label} must say plainly that no cert stands in:\n#{refused}"
        refute_includes refused, OFFERS_CERT,
                        "#{label}: NO printer in a verdict may name a route the gate cannot honour:\n#{refused}"

        certified, cert_code = refusal(path, ci: state, pr_files: pr_files, receipts: FULL_CERT_RECEIPTS)
        assert_equal 1, cert_code, "#{label}: a recorded full cert must NOT advance it:\n#{certified}"
        # Byte-identical MINUS the suggestions: the base-movement audit names the per-run
        # tmpdir it could not read a ref in, so two runs differ there by construction.
        assert_equal verdict_lines(refused), verdict_lines(certified),
                     "#{label} says a cert does not stand in — so adding one must change NOTHING, byte for byte"
      end
    end
  end

  def verdict_lines(out)
    out.lines.reject { |l| l.include?("ⓘ suggestion:") }.join
  end

  # THE CONTROL FOR THE VARIANT ABOVE: prove the unreadable-PR input actually reaches
  # the path. A `pr_files: :unreadable` run that silently behaved like a readable one
  # would make every assertion above pass while testing nothing.
  ALERT_MARK = "so this verdict did NOT read the PR"

  def test_the_unreadable_pr_file_list_variant_actually_reaches_the_second_printer
    with_alert, = refusal(:exempt, ci: "unreadable", pr_files: :unreadable)
    assert_includes with_alert, ALERT_MARK,
                    "the pr_files: :unreadable world must actually fire pr_read_alert:\n#{with_alert}"

    without_alert, = refusal(:exempt, ci: "unreadable", pr_files: :readable)
    refute_includes without_alert, ALERT_MARK,
                    "the readable world must NOT fire it, or the two worlds are the same test"
  end

  # ── [unit] the denial at the source, in both roles ──────────────────────────
  def test_unit_no_verdict_refusal_offers_a_cert_in_either_role
    %i[none unverified unreadable].each do |state|
      ci = { state: state, reason: "403", cause: :permissions }
      [true, false].each do |review_role|
        message = CiGate.verdict(ci, review_role: review_role, pr_url: PR_URL, slug: "t")
        refute_includes message, OFFERS_CERT, "#{state}/review_role:#{review_role}: the retired offer is back"
        assert_includes message.downcase, DENIES_CERT.downcase,
                        "#{state}/review_role:#{review_role}: the refusal must say nothing stands in:\n#{message}"
      end
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
      [true, false].each do |review_role|
        message = CiGate.verdict({ state: state }, review_role: review_role, pr_url: PR_URL, slug: "t")
        refute_match(/NO workflows at all/, message,
                     "#{state}: every repo here ships a pull_request workflow — that premise is false")
        refute_match(/no check will ever appear/i, message,
                     "#{state}: 'never' is a property of the PR's merge state (:conflicted/:ci_less), not a repo")
      end
    end
  end

  # ── [unit] THE CALL-SITE REGISTRY: a comment that checks itself ────────────
  # `CiStatus.unreadable_remedy` names every production caller and its route in a comment. This
  # pins that list to SOURCE: add, delete, or flip a caller between "states its route" and
  # "takes the default", and this fails and hands the author the comment to update. The hash
  # audits only typed files, so the FILE SET is globbed separately: see `bin_files` and the set
  # test below. bin/release.rb states release_grain: true at the G3 and G4 gates; the other
  # callers take the default. Re-derive counts with the scan below.
  # History: task exempt-refusal-prints-dead-remedy.
  UNREADABLE_REMEDY_CALL_SITES = {
    "bin/lib/ci_gate.rb" => { states_route: 0, takes_default: 1 },
    "bin/dor-check" => { states_route: 0, takes_default: 1 },
    "bin/pr-review" => { states_route: 0, takes_default: 1 },
    # G3's pre_qa_ci_abort and G4's ship_test_gate_ci_abort — both release-grain
    # denials (release_grain: true); the ship gate reads CI for the frozen tree exactly as G3
    # reads it for the release tip, so its :unreadable branch carries the same remedy.
    "bin/release.rb" => { states_route: 2, takes_default: 0 }
  }.freeze

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

  # THE CANDIDATE SET: GLOBBED, NEVER LISTED. UNREADABLE_REMEDY_CALL_SITES is keyed by file path
  # and the count test iterates it, so a caller in a NEW file is killed only by the set test
  # below. bin/lib/ci_status.rb's header promises the registry "fails when [a caller] appears,
  # vanishes, or changes route"; this net makes that true of a new file. EVERY FILE UNDER bin/,
  # deliberately not `bin/**/*.rb`: bin/dor-check and bin/pr-review are extensionless. Every
  # narrower rule is a hole of the same shape.
  # History: task registry-blind-to-files.
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
      stating, defaulting = args.partition { |arg| arg.include?("release_grain:") }

      assert_equal expected[:states_route], stating.size,
                   "#{file}: callers STATING release_grain: changed. Update the call-site list in " \
                   "CiStatus.unreadable_remedy's header, then this registry — the comment is the " \
                   "deliverable, this test is only what keeps it true.\n#{stating.join("\n---\n")}"
      assert_equal expected[:takes_default], defaulting.size,
                   "#{file}: callers TAKING the release_grain: default changed. A new default-taker is a new " \
                   "promise nobody classified — decide its route, then update ci_status.rb's list and " \
                   "this registry.\n#{defaulting.join("\n---\n")}"
    end
  end

  # pr_read_alert used to forward its callers' cert route (five printing callers passed
  # true, the exempt one false, three predicate uses discarded the string). It takes
  # no route now, because none exists to forward — and a caller that grew one back
  # would be re-arming an offer the gate cannot honour.
  def test_unit_pr_read_alert_takes_no_route
    source = code_of("bin/dor-check")

    assert_match(/^def pr_read_alert$/, source, "pr_read_alert must take no parameters")
    refute_includes source, "cert_route", "bin/dor-check must name no cert route anywhere — there is none"
  end

  # ── the closing line that outlived its truth ──
  # CiStatus.unreadable_remedy's exempt branch must not promise green is sufficient when
  # something else refuses: one stale App token refuses the PR read AND the check read, so on a
  # co-fire green is NECESSARY but not SUFFICIENT. THE FIX IS A DERIVATION, NOT A REWRITE,
  # pinned as a PAIR identical but for `pr_files:`. The sentence depends on ONE input, whether
  # anything else is refusing; rewording it unconditionally changes what operators read on every
  # non-co-fire refusal.
  # History: task gate-sentence-outlived-truth.

  # The sentence operators already know, pinned as a LITERAL. Recomputing it from the
  # method under test would make the fence agree with any rewrite of that method,
  # which is the fence disarmed rather than the fence passing.
  GREEN_SUFFICIENT = "Fixing the credential is the only route — this gate advances on a GREEN CI and nothing else."
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
  # THE OLD GATED ROUTE (`true`) IS THE SAME TASK-GRAIN DENIAL AS `false` — the two
  # used to differ by the cert offer, and the offer is gone. Asserted as EQUALITY so a
  # divergence between them (an offer creeping back on one) fails here.
  def test_unit_the_true_route_is_the_same_task_grain_denial_as_false
    REMEDY_CAUSES.each do |cause|
      offered = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause)
      denied = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause, release_grain: false)

      assert_equal denied, offered, "#{cause.inspect}: the default and false must print one denial"
      assert_includes offered, DENIES_CERT, "#{cause.inspect}: the denial carries the contract clause"
      refute_includes offered, OFFERS_CERT, "#{cause.inspect}: the retired offer is back"
      refute_includes offered, CO_FIRE_CLAIM, "#{cause.inspect}: the derived clause must not leak on an empty list"
    end
  end

  # AND THE EXEMPT ROUTE WITH AN EMPTY LIST — the default every non-co-fire caller
  # takes — is byte-identical too. Stated on the METHOD as well as through the binary
  # because the binary test above can only reach one cause.
  def test_unit_an_empty_also_refused_prints_the_original_exempt_closing
    REMEDY_CAUSES.each do |cause|
      [false].each do |route|
        remedy = CiStatus.unreadable_remedy(REMEDY_REPO, cause: cause, release_grain: route)

        assert remedy.end_with?(GREEN_SUFFICIENT),
               "#{cause.inspect}/#{route.inspect}: an empty also_refused must close with the original " \
               "sentence, to the byte:\n#{remedy}"
      end
    end
  end

  # ── the grain is a keyword, so it cannot be misspelled (guard catalog row 1.11) ──

  # The retired `cert_route:` took a symbol, a symbol could be misspelled, and a
  # validator fenced it. `release_grain:` is a boolean keyword: a misspelled NAME is
  # Ruby's own ArgumentError, and there is no value to misspell. This is the control.
  def test_unit_a_misspelled_grain_keyword_raises_before_printing_anything
    error = assert_raises(ArgumentError) do
      CiStatus.unreadable_remedy(REMEDY_REPO, cause: :credentials, release_grian: true)
    end

    assert_includes error.message, "release_grian"
    assert_raises(ArgumentError) { CiStatus.unreadable_remedy(REMEDY_REPO, cert_route: :retired) }
  end

  # ONE FENCE, ONE ENTRY POINT. CiGate.unread_ci_refusal used to forward this parameter
  # and branch on it for :none/:unverified, so the fence had to live in both files;
  # it takes no route now, and the :retired denial it could once be handed is the
  # release gate's alone (test/lib/release_pre_qa_remedy_test.rb). What CiGate must
  # still do is deny in every role without ever offering the cert it retired.
  def test_unit_ci_gate_denies_the_cert_in_both_roles_for_every_no_verdict_state
    %i[none unverified unreadable].each do |state|
      [true, false].each do |review_role|
        message = CiGate.unread_ci_refusal({ state: state, reason: "403", cause: :permissions }, PR_URL, "t",
                                           review_role: review_role)

        refute_includes message, "certify in full instead",
                        "#{state}/review_role:#{review_role}: an offer crept back:\n#{message}"
        assert_includes message.downcase, "no local cert stands in",
                        "#{state}/review_role:#{review_role}: the denial must carry the CONTRACT CLAUSE:\n#{message}"
      end
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

  # ── the WIDENED half of that closing line ──
  # A fence, not a defect: bin/lib/ci_gate.rb's :none/:unverified branch carries
  # CiStatus.unreadable_remedy's promise. Forcing `no_verdict_close` to print either wording
  # ALWAYS must fail here. THE PAIR IS DELIBERATE: the two tests differ by ONE input, whether
  # anything else is refusing this verdict, the only input the sentence may depend on. RUN
  # TWICE, at two grains: CiGate can format the clause perfectly while bin/dor-check never hands
  # it the list. The unit pair pins the FORMATTER; the binary pair pins the WIRING.
  # History: task fence-the-widened-closing.

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
      message = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t", also_refused: [PR_READ_NOUN_PHRASE])

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
    gate = CiGate.unread_ci_refusal({ state: :none }, PR_URL, "t", also_refused: [PR_READ_NOUN_PHRASE])
    status = CiStatus.unreadable_remedy(REMEDY_REPO, cause: :credentials, release_grain: false,
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
      message = CiGate.unread_ci_refusal({ state: state }, PR_URL, "t")

      assert message.end_with?(NO_VERDICT_GREEN_SUFFICIENT),
             "#{state}: with nothing else refusing, the wording operators know must survive VERBATIM — an " \
             "over-broad fix that reworded it here is what this catches:\n#{message}"
      refute_includes message, CO_FIRE_CLAIM, "#{state}: nothing is refusing this verdict besides CI:\n#{message}"
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
  # unclassified-state branch argues NECESSITY only: this state is not green, therefore refuse.
  # So the sentence says what the allow-list enforces: green is alone in PASSING. The shape,
  # tier and PR-read gates each refuse on a fully green CI, so "advances" would overclaim. BOTH
  # retired spellings are refuted below, because a correction that drops its predecessor's name
  # is how the predecessor comes back.
  # History: task fence-the-widened-closing.
  def test_unit_the_unclassified_refusal_argues_from_necessity_not_sufficiency
    message = CiGate.unread_ci_refusal({ state: :surprise }, PR_URL, "t")

    assert_includes message, "GREEN is this gate's sole PASSING CI state",
                    "the refusal must argue from what the allow-list enforces:\n#{message}"
    refute_includes message, "advances on a GREEN CI and nothing else",
                    "THE FIRST RETIRED CLAIM: green advances the CI allow-list, not the gate — the shape, tier " \
                    "and PR-read gates all refuse on a fully green CI:\n#{message}"
    refute_includes message, "the only CI state that advances a review",
                    "THE SECOND RETIRED CLAIM: advancing and passing are different predicates:\n#{message}"
  end

  # ── the supervisor's own copy of the sentence ──
  # bin/pr-review's `cert_caveat` must not close "green is the only thing that advances it". It
  # prints at exactly two lines, the :unreadable branch and the :unverified `else`, the
  # co-fire's OWN TRIGGERS, where green is NECESSARY AND NOT SUFFICIENT
  # (docs/agents/agents/carl/sops/pr-review-primary.md). A SOURCE TEST: `cert_caveat` is a local
  # in a method that spawns real reviewer subprocesses, so there is no value seam. The
  # supervisor and the gate must tell ONE story, in ONE spelling, at BOTH print sites.
  # History: task fence-the-widened-closing.
  SUPERVISOR_GREEN_SUFFICIENT = "green is the only thing that advances it"

  def pr_review_source = File.read(File.join(REPO_ROOT, "bin/pr-review"))

  # THE SAME FILE WITH ITS COMMENT-ONLY LINES REMOVED: what the script can actually PRINT. A
  # whole-file scan cannot tell a comment quoting the retired sentence on purpose from a live
  # promise. HEREDOC BODIES ARE NOT COMMENTS: bin/pr-review's PROMPT/TEXT heredocs carry
  # markdown headings beginning with `#`, where a flat "drop every line starting with #" would
  # hide the claim. So heredoc bodies are tracked and kept. `#{` is kept too: an interpolation
  # is code. Trailing comments stay, so a claim on a code line still trips
  # test_unit_the_supervisor_stops_promising...
  # History: task fence-the-widened-closing.
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
  # bin/pr-review's heredoc lines beginning with `#` are all `#{...}`, kept by the interpolation
  # exemption, so driving this control against the real file would exercise nothing in the
  # heredoc branch. That is CHECKED, not asserted in prose. ITS OWN TEST, NOT A PRELUDE TO THE
  # FIXTURE'S: in one method with the scans first, a firing alarm stops Minitest before the four
  # fixture assertions run. Two methods, not a reordering: order only chooses which half goes
  # blind.
  # History: task exempt-path-claim-unqualified.
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

  # ONE LITERAL, TWO SITES, TWO CAUSES. The caveat prints at :unreadable (GitHub refused the
  # credential) and the :unverified `else` (a gh/network fault), so its closing must name the
  # CLASS they share. SO ASSERT THE SHAPE OF THE CLAIM: the clause ("hides both reads" to the
  # next `;`) must name the credential cause and the transport cause, join them disjunctively,
  # and EXCLUDE neither. Scope the exclusion check to the clause: a whole-literal scan red-seals
  # "NECESSARY AND NOT SUFFICIENT". STILL BLIND to re-weighting a cause ("...; usually the
  # token"): this reads syntax, so do not mistake the pin for a proof.
  # History: task exempt-path-claim-unqualified.
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

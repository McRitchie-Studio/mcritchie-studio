# frozen_string_literal: true

# The pre-QA gate (G3): CI verdict reads, polling, tree-identical credit, the suite
# command argv and the gate's recorded certification.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_pre_qa_gate_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliPreQaGateTest < ReleaseCliHarness
  # --- pre-QA gate: the prepare-owned test tier on origin/release --------------

  def test_prepare_dry_run_previews_the_pre_qa_gate_per_app
    setup = STUB_CONDUCTOR + %(\ndef qa_gate_cmd(repo) = repo == "mcritchie-studio" ? "bin/rails test:integration" : "")
    out = run_cli(["--dry-run"], call: "prepare", setup: setup)

    # DevOps v2 Phase 3: the banner names what the step does now — read GitHub CI's
    # verdict for each app's origin/release SHA. The registered qa_test_cmd is still
    # RECORDED on the release (the audit trail), just no longer executed anywhere local.
    assert_includes out, "pre-QA gate: GitHub CI's verdict for each app's origin/release SHA " \
                         "(before any QA deploy)"
    # The preview states the CI verdict is the gate and the command is RECORDED (not
    # run) — the plan matches what a real run executes.
    assert_includes out, "[dry-run] pre-QA gate mcritchie-studio: GitHub CI verdict for origin/release " \
                         "(bin/rails test:integration ran in CI; recorded, not run)"
    assert_includes out, "turf-monster: no qa_test_cmd registered", "an unregistered app self-gates (skip)"
  end

  def test_pre_qa_gate_runs_before_any_qa_deploy
    setup = STUB_CONDUCTOR + %(\ndef qa_gate_cmd(_repo) = "bin/rails test:integration")
    out = run_cli(["--dry-run"], call: "prepare", setup: setup)

    gate_at   = out.index("pre-QA gate mcritchie-studio")
    deploy_at = out.index("bin/qa-server deploy mcritchie-studio")
    assert gate_at && deploy_at, "both the gate and the deploy must appear"
    assert_operator gate_at, :<, deploy_at, "the gate runs BEFORE the QA deploy (members still reviewed)"
  end

  def test_pre_qa_gate_red_aborts_with_eject_guidance
    # DevOps v2 Phase 3: the RED verdict now comes from GitHub CI, not a local suite —
    # a red CI is a regression riding origin/release, and the abort routes to the
    # eject/revert/keep-the-rest recovery exactly as the local-suite red used to.
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "red"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a red CI verdict aborts prepare (fail-closed)"
      assert_includes out, "GitHub CI called", "…NAMING GitHub CI as the source of the RED verdict"
      assert_includes out, "regression is riding origin/release"
      assert_includes out, "bin/release eject", "the abort points at the block-on-regression move"
      assert_includes out, "git revert -m 1", "…and the merge-commit revert"
      assert_includes out, "REST of the RC rides on", "keep-the-rest is the stated recovery"
      refute_includes out, "PASSED"
    end
  end

  # [unit] ci_pass? is THE gate verdict, fail-closed: :green is the ONLY pass; red and
  # EVERY no-data/pending/unknown state fail closed, and so do nil and a stateless hash.
  # This is the single invariant a false-green would violate — an untested SHA would ship.
  # A STRING "green" is not the :green symbol ci_verdict returns, so it fails closed too:
  # no loose coercion where a false pass ships code.
  def test_ci_pass_is_true_only_for_green_and_fails_closed_on_everything_else
    assert_equal "true", eval_helper(%(ci_pass?({ state: :green }))), "green is the ONLY pass"
    %i[red none pending unverified unreadable no_pr closed merged conflicted].each do |state|
      assert_equal "false", eval_helper(%(ci_pass?({ state: #{state.inspect} }))),
                   "#{state} must FAIL CLOSED — an absent/unknown/red verdict never certifies a SHA"
    end
    assert_equal "false", eval_helper(%(ci_pass?(nil))), "a nil verdict fails closed"
    assert_equal "false", eval_helper(%(ci_pass?({}))), "a stateless verdict fails closed"
    assert_equal "false", eval_helper(%(ci_pass?({ state: "green" }))),
                 "a STRING 'green' is not the :green symbol — fail closed, no loose coercion"
  end

  # [unit] ci_poll_action is the PURE poll decision (the CI-verdict analogue of
  # Release::ShipSequence.run_watch_verdict), factored so pending→hold / green→certify /
  # red→abort / unreadable→abort is testable without a poll loop or a clock. The POSITIVE
  # invariant, asserted directly (not by blacklisting failure spellings): GREEN is the
  # ONLY :pass; :red, :unreadable and :ci_less are the ONLY :abort — a terminal
  # non-green that waiting can never turn green (:ci_less because GitHub will run NO
  # CI at all for a stale base, so there is no run to wait for — task
  # detect-ci-less-stale-prs); EVERY other state is :wait, so a just-merged SHA's
  # not-yet-concluded CI is HELD and re-read instead of aborting the sweep's first run.
  # It is also proven against states the gate never actually feeds it (no_pr/closed/
  # merged/conflicted) so the rule holds for vectors nobody has to enumerate — they hold
  # then fail closed at the timeout, never a false pass.
  def test_ci_poll_action_classifies_each_verdict
    assert_equal ":pass", eval_helper(%(ci_poll_action({ state: :green }).inspect)), "green certifies"
    assert_equal ":pass", eval_helper(%(ci_poll_action({ state: :green, count: 3 }).inspect)),
                 "green with detail still certifies"
    %i[red unreadable ci_less].each do |state|
      assert_equal ":abort", eval_helper(%(ci_poll_action({ state: #{state.inspect} }).inspect)),
                   "#{state} is terminal — abort now, never poll a verdict waiting cannot fix"
    end
    %i[none pending unverified no_pr closed merged conflicted].each do |state|
      assert_equal ":wait", eval_helper(%(ci_poll_action({ state: #{state.inspect} }).inspect)),
                   "#{state} has no green verdict YET — hold and re-read, do not abort the sweep"
    end
    assert_equal ":wait", eval_helper(%(ci_poll_action(nil).inspect)),
                 "a nil verdict holds (fails closed at the timeout, never a false pass)"
    assert_equal ":wait", eval_helper(%(ci_poll_action({}).inspect)), "a stateless verdict holds"
  end

  # [unit] fast_forward_promote? — the SAME-SHA precondition for the G3 credit
  # (task dedupe-hub-release-suite), the same-SHA discipline G4's read shares: the
  # credit may engage ONLY when origin/release IS the accepted head CI already
  # built. A diverged tip (the batch-PR merge commit), an unresolvable accepted
  # ref, and a blank release SHA all answer false — no credit, normal poll, never
  # an abort.
  def test_fast_forward_promote_is_true_only_when_release_is_the_accepted_head
    same = %(def sh(*a, **_k)\n  a.include?("origin/accepted") ? [GATE_SHA, true] : ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", GATE_SHA).inspect))
    assert_equal "true", out, "release SHA == accepted head is the fast-forward shape"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", "1111111111111111111111111111111111111111").inspect))
    assert_equal "false", out, "a diverged release tip (merge-commit promote) must not read as a fast-forward"

    failed = %(def sh(*a, **_k) = ["", false]\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + failed,
                  call: %(print fast_forward_promote?("/x", GATE_SHA).inspect))
    assert_equal "false", out, "an unresolvable accepted ref answers false, never an abort"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", "").inspect))
    assert_equal "false", out, "a blank release SHA can never be a fast-forward"
  end

  # [integration] GREEN CI certifies: the gate passes on a green CI verdict for the
  # SHA under test, states that verdict, and records ok:true WITH CI's verdict for the
  # audit trail (record_qa_gate — nothing gates on it; G4 reads CI for the frozen tree).
  def test_pre_qa_gate_records_a_green_ci_verdict_as_the_certification
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "green"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}", "the gate STATES the CI verdict it gated on"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a green gate records its certification: #{out}"
      assert_includes record, "record_qa_gate", "…through the same conductor write as before"
      assert_includes record, "ok: true", "a green CI records ok:true"
      assert_match(/ci:\s*\{/, record, "…carrying CI's verdict for the same SHA")
      assert_match(/"state"\s*=>\s*"green"/, record)
      assert_includes out, "PASSED"
    end
  end

  # [integration] RED CI FAILS CLOSED. GitHub says RED for the SHA under test —
  # under DevOps v2 Phase 3 CI IS the verdict, so the gate ABORTS (it does not deploy
  # to QA) and records ok:FALSE with CI's verdict (a red G3 must be recorded as failed,
  # never silently un-stamped). A RAW check-runs payload exercises the mapping shim
  # end-to-end: status+conclusion → bucket → verdict, no network.
  def test_pre_qa_gate_fails_closed_when_ci_is_red
    Dir.mktmpdir do |dir|
      payload = '{"total_count":2,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"completed","conclusion":"failure"}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a RED CI verdict FAILS the gate — CI is the verdict now, not an auditor"
      assert_includes out, "GitHub CI called #{GATE_SHA[0, 7]} RED", "…naming the SHA and the source"
      assert_includes out, "test:system", "…and the failing check"
      assert_includes out, "regression is riding origin/release"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a red gate must be RECORDED as failed, not silently un-stamped: #{out}"
      assert_includes record, "ok: false", "the red verdict records ok:false"
      assert_match(/"state"\s*=>\s*"red"/, record, "…carrying CI's red verdict for the audit trail")
      refute_includes out, "PASSED"
    end
  end

  # [integration] A PENDING CI IS POLLED UNTIL IT CONCLUDES — THE FIX. A just-merged
  # release SHA reports its push CI :pending for the first minutes; Slice 3's single read
  # aborted every sweep's first run on it (observed @ 015241f, @ f05cdf5), forcing a manual
  # "wait for release CI, re-run bin/release prepare" round-trip. The gate now HOLDS and
  # re-reads: two pending reads, then green → it PASSES and certifies. ci_verdict CHANGES
  # across reads, so this drives the real poll loop, not a static injected verdict.
  def test_pre_qa_gate_polls_a_pending_ci_until_it_concludes_green
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_poll_gate_stub(dir),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("READS=" + $ci_reads.to_s); puts("PASSED")})

      assert_includes out, "holding for it to conclude", "a pending CI is HELD, not aborted on the first read"
      assert_includes out, "READS=3", "it re-read until CI concluded (2 pending + 1 green), not once"
      assert_includes out, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}", "the concluded verdict is the one it gates on"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "the green conclusion is certified: #{out}"
      assert_includes record, "ok: true", "a polled-to-green CI records ok:true"
      assert_includes out, "PASSED", "the gate passes once CI concludes green"
    end
  end

  # [integration] NO GREEN VERDICT FAILS CLOSED after the poll times out — the single most
  # important invariant. A missing run (:none), a still-running push CI (:pending), and a
  # gh/network read miss (:unverified) are all "GitHub has no GREEN verdict for this SHA
  # YET". These are :wait states, so the gate POLLS them; with the window collapsed to a
  # single read (ci_gate_stub sets RELEASE_CI_POLL_TIMEOUT=0) a verdict that never turns
  # green fails CLOSED — an absent/unknown verdict must NEVER read as a pass (a false green
  # deploys an untested SHA to QA). It records ok:false rather than certifying blind.
  def test_pre_qa_gate_fails_closed_when_ci_never_reaches_green
    %w[none pending unverified].each do |state|
      Dir.mktmpdir do |dir|
        out = run_cli(["--yes"], setup: ci_gate_stub(dir, state),
                      call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

        assert_includes out, "ABORTED", "#{state}: an absent/unknown CI verdict must FAIL CLOSED, never pass"
        assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}", "#{state}: names what it could not certify"
        assert_includes out, "FAILS CLOSED", "#{state}: the gate says why it held"
        assert_includes out, "poll timed out", "#{state}: it POLLED for a conclusion, not aborted on the first read"
        refute_includes out, "PASSED", "#{state}: a green never comes out of no-data"
      end
    end
  end

  # [integration] AN UNREADABLE CI ABORTS IMMEDIATELY — it does NOT poll. :unreadable is a
  # token/credential fault, and a refused token never heals mid-sweep, so polling it would
  # only burn the whole timeout to no end. The gate fails closed on the FIRST read and
  # prints the one shared credential remedy (CiStatus.unreadable_remedy), never a "wait for
  # CI to conclude" hold. This is the deliberate split from the no-data hold above.
  def test_pre_qa_gate_fails_closed_immediately_on_an_unreadable_ci
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "unreadable"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "an unreadable CI verdict fails the gate closed"
      assert_includes out, "UNREADABLE for #{GATE_SHA[0, 7]}", "…naming the SHA it could not read"
      assert_includes out, "credential/token fault", "…as a credential fault, not a missing CI"
      assert_includes out, "does NOT poll it", "…and it did NOT poll a broken token"
      refute_includes out, "poll timed out", "unreadable aborts on the FIRST read — no poll window is spent"
      refute_includes out, "PASSED"
    end
  end

  # [integration] EXISTING GREEN CREDITED — the fix. A fast-forwarded promote +
  # an already-green SHA passes the gate WITHOUT polling out the duplicate run
  # (timeout 0: a poll would have failed closed), states the credit, and records
  # the credited source in the gate note (record_qa_gate's ci half) with ok:true
  # for the release's audit trail.
  def test_pre_qa_gate_credits_an_existing_green_conclusion_on_a_fast_forward_promote
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "the gate SAYS it credited, and for which SHA"
      assert_includes out, "no duplicate run awaited", "…and that no poll window was spent on the duplicate"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}",
                      "the gate line marks the credited verdict apart from a polled one"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a credited gate still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true", "a credited green records ok:true"
      assert_match(/"credited"\s*=>/, record, "the gate note records the credited source")
      assert_includes record, "fast-forward promote", "…naming WHY the credit applied"
      assert_includes out, "PASSED", "the gate passes on the credit — no duplicate suite run awaited"
    end
  end

  # [unit] The G3 gate run records its OWN SOP per app — CI's state, the SHA and the
  # verdict's SOURCE — the same line the G4 read records, so both gate runs read alike
  # on the release. (Outside a gate window $gate_sops is nil and the hook is a no-op.)
  def test_pre_qa_gate_records_a_pre_qa_gate_sop_naming_the_verdict_source
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD),
                    call: %{$gate_sops = []; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("SOPS " + $gate_sops.inspect); puts("PASSED")})

      sops = out.lines.find { |l| l.start_with?("SOPS") }
      assert sops, "the G3 read must record a gate SOP: #{out}"
      assert_includes sops, %("sop"=>"pre_qa_gate")
      assert_includes sops, %("result"=>"pass")
      assert_includes sops, "GitHub CI GREEN @ #{GATE_SHA[0, 7]} — credited — ", "the SOP names the verdict's SOURCE"
      assert_includes sops, "fast-forward promote"
      assert_includes sops, "bin/suite ran in CI, not here"
      assert_includes out, "PASSED"
    end
  end

  # [integration] NO FAST-FORWARD, NO SAME-SHA CREDIT — and diverged TREES refuse
  # the tree credit too. The promote here minted a merge commit (origin/release !=
  # origin/accepted) whose tree ALSO differs from accepted's, so NEITHER credit may
  # engage: not the same-SHA one (the fast-forward discipline) and not the
  # tree one (a different tree is different content — nothing vouches for it).
  # With the poll window collapsed, the pending duplicates fail closed exactly as
  # before the credit existed. (The diverged-SHA-but-IDENTICAL-tree shape credits —
  # that is the live batch-PR case, asserted by the tree-credit tests below.)
  def test_pre_qa_gate_does_not_credit_without_a_fast_forward_promote
    Dir.mktmpdir do |dir|
      diverged = %(\ndef sh(*a, **k)\n) +
                 %(  return ["2222222222222222222222222222222222222222", true] if a.include?("origin/accepted")\n) +
                 %(  return ["1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a", true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
                 %(  return ["2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b", true] if a.last.to_s.end_with?("^{tree}")\n) +
                 %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD) + diverged,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a diverged promote must never engage either credit"
      assert_includes out, "shares neither SHA nor tree", "the non-credit is NAMED, not silent (no hand-forensics)"
      assert_includes out, "ABORTED", "…so the pending duplicates fail closed exactly as before"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}"
      refute_includes out, "PASSED"
    end
  end

  # [integration] RED STILL BLOCKS — byte-for-byte. A failed run anywhere in the
  # record refuses the credit (even alongside completed greens and their queued
  # duplicates, on a genuine fast-forward), so the gate reads the SHA RED and
  # aborts with the same eject/revert guidance as ever.
  def test_pre_qa_gate_credit_never_overrides_a_red
    Dir.mktmpdir do |dir|
      payload = '{"total_count":4,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"completed","conclusion":"failure"},' \
                '{"name":"test","status":"queued","conclusion":null},' \
                '{"name":"test:system","status":"queued","conclusion":null}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a red record must never be re-read as a credit"
      assert_includes out, "ABORTED", "a red CI verdict still fails the gate closed"
      assert_includes out, "GitHub CI called #{GATE_SHA[0, 7]} RED"
      assert_includes out, "test:system", "…naming the failing check"
      refute_includes out, "PASSED"
    end
  end

  # [integration] A GENUINE WAIT STILL WAITS. A pending check with NO completed
  # counterpart is the ORIGINAL suite still running — not a duplicate — so the
  # credit declines and the gate holds/fails closed on the poll exactly as before.
  def test_pre_qa_gate_does_not_credit_a_half_finished_original_suite
    Dir.mktmpdir do |dir|
      payload = '{"total_count":2,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"in_progress","conclusion":null}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a half-finished first run must never credit"
      assert_includes out, "no completed green to credit yet", "the fast-forward decline is NAMED, not silent"
      assert_includes out, "ABORTED", "…the still-running suite fails closed at the (collapsed) poll window"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}"
      refute_includes out, "PASSED"
    end
  end

  # [integration] THE LIVE PATH CREDITS BY TREE — the round-2 fix. A batch-PR merge
  # commit (release != accepted) with the accepted head's tree, whose accepted-head
  # CI already concluded green, passes the gate WITHOUT polling out the duplicate
  # release-push run (timeout 0: the release SHA reads pending, so a poll would
  # have failed closed). The gate note records BOTH full SHAs + the shared tree.
  def test_pre_qa_gate_credits_the_accepted_head_green_on_a_tree_identical_promote
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "the gate SAYS it credited, and for which release SHA"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}",
                      "the gate line marks the credited verdict apart from a polled one"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a tree-credited gate still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true", "a tree-credited green records ok:true"
      assert_includes record, "tree-identical promote", "the note names WHY the credit applied"
      assert_includes record, ACC_SHA, "…and the accepted head whose run vouched (full SHA)"
      assert_includes record, GATE_SHA, "…and the release merge commit it vouched for (full SHA)"
      assert_includes record, SHARED_TREE, "…and the one tree both SHAs snapshot"
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE LOCK-BUMP INTERACTION (cross-PR contract pinned on PR #588,
  # publish-gems-before-qa). When a gem rides, prepare's step 4c commits each
  # consumer's Gemfile.lock bump onto `release` BEFORE pre_qa_gate resolves
  # origin/release — so the SHA gated here is the post-bump commit and its tree NO
  # LONGER matches the accepted head's. The credit must REFUSE (nothing green ever
  # ran the bumped tree) and the poll path must RUN: with the window collapsed and
  # the post-bump SHA's own CI still pending, the gate fails closed via today's
  # exact abort — proof the verdict came from the poll, not a credit.
  def test_pre_qa_gate_lock_bump_on_release_refuses_the_tree_credit_and_polls
    Dir.mktmpdir do |dir|
      bumped_tree = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: bumped_tree),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a lock-bumped release tree has NO green run behind it — never credit"
      assert_includes out, "ABORTED", "…so the gate holds/fails closed at the poll exactly as today"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}",
                      "today's poll-path abort, naming the post-bump SHA under test"
      refute_includes out, "PASSED"
    end
  end

  # [integration] The lock-bump companion: the post-bump SHA earns its OWN verdict.
  # Same diverged-tree shape, but the release SHA's CI (the push run on the bumped
  # commit) concluded green — the gate passes off the POLL, and the record carries
  # NO credited key: the verdict was earned, not vouched.
  def test_pre_qa_gate_lock_bump_sha_passes_on_its_own_polled_green
    Dir.mktmpdir do |dir|
      bumped_tree = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: bumped_tree, release_ci: ":green"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      refute_includes out, "crediting", "no credit engaged — the bumped tree earned its own green"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "the polled green still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true"
      refute_includes record, "credited", "a polled verdict records NO credited source"
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE WAIT TIMES OUT → FALL THROUGH. The accepted head is IN FLIGHT
  # but never concludes, and here the poll budget is collapsed to zero — so the gate
  # tries the in-flight wait, finds no budget, and falls through to poll the release
  # SHA's own run exactly as today (also pending → fails closed). Pending evidence
  # still certifies NOTHING, and a wait that cannot conclude never fabricates a green.
  def test_pre_qa_gate_tree_credit_wait_times_out_and_falls_through_when_pending
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE, accepted_ci: ":pending"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "pending evidence certifies nothing — no credit"
      assert_includes out, "did not conclude before the poll budget", "it TRIED the in-flight wait, then fell through"
      assert_includes out, "ABORTED", "…the gate holds/fails closed at the (collapsed) release-SHA poll"
      refute_includes out, "PASSED"
    end
  end

  # [integration] STRICT FALL-THROUGH: red evidence never credits — and never
  # aborts THROUGH the credit either. A red accepted-head run refuses the credit
  # and the gate takes today's poll on the release SHA (whose own run delivers its
  # own verdict — here still pending, so the collapsed window fails closed with
  # today's abort, not a credit-path one).
  def test_pre_qa_gate_tree_credit_declines_on_red_accepted_evidence
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE, accepted_ci: ":red"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a red evidence run must never be re-read as a credit"
      assert_includes out, "ABORTED"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}", "…failing closed on the RELEASE SHA's own poll"
      refute_includes out, "PASSED"
    end
  end

  # [integration] THE FIX — an IN-FLIGHT accepted run is WAITED ON, not duplicated.
  # MEASURED on rel-20260720-1fc111: in a fast pipeline the accepted CI is still
  # BUILDING when the sweep reaches the gate, so the completed-green credit fell
  # through and the hub ran the identical suite TWICE. The gate now recognises an
  # in-flight accepted run on the identical tree and WAITS on it (same wall-clock,
  # the duplicate release run skipped) — polling it to its green conclusion and
  # crediting it, while the release SHA's own run is never awaited.
  def test_pre_qa_gate_waits_on_the_inflight_accepted_run_and_credits_it
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_wait_gate_stub(dir),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("ACC_READS=" + $acc_reads.to_s); puts("PASSED")})

      assert_includes out, "waiting on it instead of re-running the duplicate",
                      "an in-flight accepted run on the identical tree is WAITED ON, not fallen-through"
      assert_includes out, "ACC_READS=3", "it polled the ACCEPTED head to its green conclusion (2 pending + 1 green)"
      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "…then credited the accepted head's green — the duplicate release run is skipped"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}"
      refute_includes out, "poll timed out", "it NEVER fell through to poll the still-pending release SHA"
      assert_includes out, "PASSED"
    end
  end

  # [unit] tree_identical_promote — the SAME-TREE precondition, answered from git:
  # {accepted_sha, tree} ONLY when the SHAs differ and the trees match; the
  # same-SHA case belongs to fast_forward_promote? (checked first), and every git
  # fault answers nil — no credit, normal poll, never an abort.
  def test_tree_identical_promote_matches_trees_only_across_differing_shas
    trees = %(def sh(*a, **_k)\n) +
            %(  return [#{ACC_SHA.inspect}, true] if a.include?("origin/accepted")\n) +
            %(  return ["5b1c78e0aaaa", true] if a.last.to_s.end_with?("^{tree}")\n) +
            %(  ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(p = tree_identical_promote("/x", GATE_SHA); print [p[:accepted_sha], p[:tree]].inspect))
    assert_equal %(["#{ACC_SHA}", "5b1c78e0aaaa"]), out,
                 "differing SHAs + one tree = the live batch-PR promote shape"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(print tree_identical_promote("/x", #{ACC_SHA.inspect}).inspect))
    assert_equal "nil", out, "release == accepted head is the fast-forward credit's case, not this one"

    split = %(def sh(*a, **_k)\n) +
            %(  return [#{ACC_SHA.inspect}, true] if a.include?("origin/accepted")\n) +
            %(  return ["1a1a1a", true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
            %(  return ["2b2b2b", true] if a.last.to_s.end_with?("^{tree}")\n) +
            %(  ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + split,
                  call: %(print tree_identical_promote("/x", GATE_SHA).inspect))
    assert_equal "nil", out, "diverged trees (a lock-bump commit on release) must answer nil"

    failed = %(def sh(*a, **_k) = ["", false]\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + failed,
                  call: %(print tree_identical_promote("/x", GATE_SHA).inspect))
    assert_equal "nil", out, "an unresolvable ref answers nil, never an abort"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(print tree_identical_promote("/x", "").inspect))
    assert_equal "nil", out, "a blank release SHA can never match"
  end

  # [unit] tree_identical_ci_outcome — the accepted-head decision for an identical
  # tree. It CREDITS a completed green (both SHAs + the tree in the note), and for
  # EVERY non-green verdict returns no credit plus a DIAGNOSTIC naming why — the gate
  # was previously silent here, which is exactly why the round-3 bug was invisible
  # without hand-forensics. A pending run with the budget already spent, and a raising
  # probe, both fall through with their own reason. (`deadline: 0` collapses the wait so
  # a :pending verdict times out at once instead of polling; the live in-flight WAIT is
  # driven end to end by test_pre_qa_gate_waits_on_the_inflight_accepted_run_and_credits_it.)
  def test_tree_identical_ci_outcome_credits_green_and_diagnoses_every_fall_through
    promote = %({ accepted_sha: #{ACC_SHA.inspect}, tree: #{SHARED_TREE.inspect} })

    green = %(def ci_verdict(_r, _s) = { state: :green, count: 8 }\n)
    out = run_cli(["--dry-run"], setup: green,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit] && o[:credit][:state], o[:credit] && o[:credit][:credited], o[:diagnostic]].inspect))
    assert_includes out, ":green", "a completed green is credited"
    assert_includes out, "tree-identical promote"
    assert_includes out, ACC_SHA, "the note names the accepted head that vouched"
    assert_includes out, GATE_SHA, "…the release merge commit vouched for"
    assert_includes out, SHARED_TREE, "…and the shared tree"

    %i[red none unverified unreadable].each do |state|
      declined = %(def ci_verdict(_r, _s) = { state: #{state.inspect} }\n)
      out = run_cli(["--dry-run"], setup: declined,
                    call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                          %(print [o[:credit], o[:diagnostic]].inspect))
      assert_match(/\Anil,|\[nil,/, out.gsub(/\s/, ""), "#{state}: nothing is credited")
      assert_includes out, "no green to credit", "#{state}: it says WHY — polling the release run instead"
      assert_includes out, state.to_s, "#{state}: the diagnostic names the verdict it saw"
    end

    pending = %(def ci_verdict(_r, _s) = { state: :pending }\n)
    out = run_cli(["--dry-run"], setup: pending,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit], o[:diagnostic]].inspect))
    assert_includes out, "nil", "a pending run with no budget credits nothing"
    assert_includes out, "did not conclude before the poll budget", "…and says the in-flight wait timed out"

    raises = %(def ci_verdict(_r, _s) = raise("boom")\n)
    out = run_cli(["--dry-run"], setup: raises,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit], o[:diagnostic]].inspect))
    assert_includes out, "nil"
    assert_includes out, "tree-credit probe errored", "a raising probe falls through with a reason"
  end

  # [integration] THE DEMOTION, affirmatively pinned (the positive replacement for the
  # skipped apparatus tests): on a GREEN CI verdict the G3 gate PASSES without ever
  # pinning an isolated workspace or booting the local suite — the verdict comes off the
  # laptop. `git worktree add`, `bin/suite`, and `bin/rails db:test:prepare` must NOT run.
  def test_pre_qa_gate_does_not_execute_the_local_suite
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = {}
        def sh(*a, **k)
          $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"
          $stdout.puts("WORKTREE-ADD") if a[0] == "git" && a.include?("worktree") && a.include?("add")
          $stdout.puts("DB-PREPARE") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "PASSED", "a green CI verdict passes the gate"
      refute_includes out, "SUITE-RAN", "the demoted local suite must NOT run — CI is the verdict"
      refute_includes out, "WORKTREE-ADD", "…and no isolated workspace is pinned"
      refute_includes out, "DB-PREPARE", "…and no gate DB is prepared"
    end
  end

  # [unit] The url the overlay carries is read from the APP's OWN config/database.yml
  # (not a registry column that can drift): a postgres app gets the gate's private DB;
  # a SQLite app gets NOTHING.
  def test_gate_database_url_is_private_for_a_pg_app_and_nil_for_a_sqlite_app
    Dir.mktmpdir do |dir|
      pg   = plant_database_yml(File.join(dir, "pg"))
      lite = plant_database_yml(File.join(dir, "lite"), adapter: "sqlite3")
      setup = %(def repo_path(repo) = repo == "turf-monster" ? #{pg.inspect} : #{lite.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{print([gate_database_url("turf-monster"), gate_database_url("rolio")].inspect)})

      assert_equal %(["postgres:///turf_monster_gate_test", nil]), out
    end
  end

  # --- G3 certification: the release's AUDIT TRAIL of what CI concluded ---------
  #
  # A GREEN CI verdict stamps release.metadata["qa_gates"][repo] = {sha, cmd, ok:true}.
  # A RED CI verdict stamps the SAME shape with ok:FALSE — an honest failed record, not
  # a silent omission (record_qa_gate's caveat). A skipped/absent gate leaves NOTHING.
  # Nothing gates on the record: G4 reads CI for the frozen ship SHA's tree itself, so
  # a record can neither skip nor arm it. The cmd is recorded in every case so the
  # trail names the suite CI ran.

  # [unit] A GREEN CI verdict records what it CERTIFIED: this repo, this SHA, this cmd,
  # ok:true. The cmd is RECORDED (not run) — it names the suite CI ran.
  def test_pre_qa_gate_records_the_g3_certification_on_a_green_ci_verdict
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cert"); puts("PASSED")})

      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "a GREEN CI verdict must record its certification: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate", "the stamp rides the tested conductor primitive"
      assert_includes cert, %(slug: "rel-cert")
      assert_includes cert, %(repo: "sibling")
      assert_includes cert, %(sha: "#{GATE_SHA}"), "it certifies the SHA CI gave a verdict on"
      assert_includes cert, %(cmd: "bin/suite"), "…and RECORDS the command (the audit trail names the suite CI ran), never runs it"
      assert_includes cert, "ok: true"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A RED CI verdict RECORDS ok:false — it must NOT silently un-stamp (the
  # record_qa_gate caveat); the honest failed stamp is what the release audit trail reads.
  def test_pre_qa_gate_records_ok_false_when_ci_is_red
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "red"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cert"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a red CI verdict still aborts the prepare (fail-closed)"
      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "a RED gate must RECORD its failure, not silently skip recording: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate"
      assert_includes cert, "ok: false", "…as ok:false — an honest failed stamp, never a green one"
      assert_includes cert, %(cmd: "bin/suite"), "the cmd is recorded even on a red verdict"
      refute_includes out, "PASSED"
    end
  end

  # [integration] The SELF-GATED-GEM pass records a first-class G3 verdict for a
  # gem-only release (gem-only-deployments). With NO app member, pre_qa_gate's gem
  # pass gates studio-engine (self-gated) on its OWN suite's CI — resolved through
  # the same repo-generic credit the apps use — and records the certification via
  # the SAME Release::Conductor.record_qa_gate primitive, with the gem's registry
  # release_check as the recorded cmd. This is what makes a gem-only publish show as
  # a first-class deployment instead of being invisible.
  def test_pre_qa_gate_self_gated_gem_records_a_g3_verdict_on_its_own_ci
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([], "rel-cert", gem_groups: [{ "repo" => "studio-engine" }]); puts("PASSED")})

      assert_includes out, "pre-QA gate studio-engine (self-gated gem): GitHub CI GREEN",
                      "the self-gated gem is gated on its own CI: #{out}"
      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "the self-gated gem must RECORD its G3 certification: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate", "the stamp rides the tested conductor primitive"
      assert_includes cert, %(slug: "rel-cert")
      assert_includes cert, %(repo: "studio-engine")
      assert_includes cert, %(sha: "#{GATE_SHA}"), "it certifies the SHA CI gave a verdict on"
      assert_includes cert, %(cmd: "bin/release-check"), "…and RECORDS the gem's own release_check as the gate cmd"
      assert_includes cert, "ok: true"
      assert_includes out, "PASSED"
    end
  end

  # [integration] The gem pass is SCOPED to a gem-only release: a self-gated gem
  # member alongside an APP member gets NO extra gem G3 gate — it is QA'd through
  # its consumer, exactly as before. Proves the gem-riding-app path is untouched.
  def test_pre_qa_gate_skips_the_gem_pass_when_an_app_rides_the_release
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = {}
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling-app" }], "rel-cert", gem_groups: [{ "repo" => "studio-engine" }]); puts("PASSED")})

      assert_includes out, "pre-QA gate sibling-app: GitHub CI GREEN", "the app gate still runs"
      refute_includes out, "self-gated gem", "no gem G3 pass fires when an app rides the release"
      assert_includes out, "PASSED"
    end
  end

  # [unit] suite_bundle_argv prefers a repo's bin/bundle binstub (same
  # env-resolved ruby as bin/rails) and falls back to `ruby -S bundle` — NEVER
  # bare `bundle` — when it carries no binstub, so the fallback still runs under
  # the mise-pinned ruby (carl + shannon's PR #480 request-changes).
  def test_suite_bundle_argv_prefers_the_binstub_and_falls_back_to_ruby_dash_s
    Dir.mktmpdir do |dir|
      _primary, workspace = build_binstub_fixture(dir)
      out = eval_helper(%([suite_bundle_argv(#{workspace.inspect}), suite_bundle_argv(#{dir.inspect})].inspect))
      assert_equal %([["bin/bundle"], ["ruby", "-S", "bundle"]]), out
    end
  end

  def test_qa_gate_cmd_reads_the_registered_g3_tier_from_the_real_registry
    # ONE subprocess reads every registered app through the REAL
    # config/release_repos.yml — the exact seam pre_qa_gate reads at run time. The
    # tier a repo registers turns on whether its DEPLOY runs the suite, not on
    # hub-vs-satellite:
    #   * the HUB and ROLIO both deploy via git_push_heroku (NO test step), so each
    #     registers CI's full suite VERBATIM — base AND system tiers. It is the same
    #     STRING for both (HUB_GATE_CMD), which is why rolio reuses the constant:
    #     both ci.yml `test` jobs run `bin/rails db:test:prepare test test:system`.
    #     For rolio this is its LAST gate before prod, and `bin/rails test` alone
    #     SKIPS its test/system — the gap this pins shut.
    #   * turf-monster keeps the integration subset — bin/deploy runs its full
    #     suite pre-prod, and it has no test/system at all.
    #   * turf-vault registers NOTHING, and this is the reader that proves it. The
    #     Rails-side Release::Repos.qa_test_cmd is nil for it, but `bin/release`
    #     reads the registry STANDALONE (no Rails), so the two could disagree. A
    #     non-empty answer here would arm a Rails gate against an Anchor repo with
    #     no bin/rails — red at G3, aborting the whole batch sweep.
    out = eval_helper(%(%w[mcritchie-studio turf-monster turf-vault rolio tax-studio chain-ops].map { |r| qa_gate_cmd(r) }.inspect))

    expected = [HUB_GATE_CMD,
                "bin/rails test test/integration", "", HUB_GATE_CMD,
                "", ""]
    assert_equal expected.inspect, out,
                 "hub + rolio certify CI's full suite at G3 (no test step in their deploy); turf-monster " \
                 "gates on integration; planned apps self-gate"
  end

  def test_test_cmd_argv_matches_plain_split_for_flag_style_commands
    # The behavior-preserving half of the Shellwords switch: every flag-style
    # command (the shape the registry carries) parses byte-identically both ways.
    out = eval_helper(%(["bin/rails test", "bin/rails test test/integration", "bin/deploy --yes"].map { |c| test_cmd_argv(c) == c.split }.inspect))
    assert_equal "[true, true, true]", out
  end

  def test_test_cmd_argv_keeps_a_quoted_spaced_arg_as_one_element
    out = eval_helper(%(test_cmd_argv(%q{bin/rails test "test/integration/a b_test.rb"}).inspect))
    assert_equal %(["bin/rails", "test", "test/integration/a b_test.rb"]), out
  end

  def test_test_cmd_argv_aborts_naming_an_unbalanced_quote
    out = run_cli(["--yes"], setup: "",
                  call: %{begin; test_cmd_argv(%q{bin/rails test "unclosed}); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a malformed command must never exec a garbled argv"
    assert_includes out, "unparseable test command"
    assert_includes out, "unclosed", "the abort names the offending string"
    assert_includes out, "config/release_repos.yml", "…and points at the registry to fix"
  end

  def test_pre_qa_gate_dry_run_still_aborts_on_a_malformed_command
    # The parse is hoisted BEFORE the dry-run return, so a broken registry value
    # surfaces in a preview instead of detonating mid-conductor later.
    setup = %(def qa_gate_cmd(_repo) = %q{bin/rails test "unclosed})
    out = run_cli(["--dry-run"], setup: setup,
                  call: %{begin; pre_qa_gate([{ "repo" => "mcritchie-studio" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "unparseable test command"
    refute_includes out, "PASSED"
  end
end

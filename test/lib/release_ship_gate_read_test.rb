# frozen_string_literal: true

# [integration] G4's tree-verdict READ on the FROZEN ship SHA (devops-v3 §5, task
# ship-gate-reads-tree-verdict). Standalone (no Rails):
#   ruby -Itest test/lib/release_ship_gate_read_test.rb
#
# One tree earns one verdict. bin/release's test_gate resolves the frozen ship SHA
# through the SAME credit-or-poll path G3 runs on the release tip
# (resolve_release_ci_verdict) and classifies what it read
# (Release::ShipSequence.ship_gate_kind — the pure state table is unit-tested in
# test/models/release/ship_sequence_test.rb; THIS is the wiring). These drive the
# REAL test_gate with injected verdicts and a stubbed git, one case per row: green
# (its own run), credited same-SHA, credited same-tree, red, held past the poll bound
# (pending / none / unverified), unreadable, diverged, and a G3 record that must not
# talk a red past the gate. In EVERY row the local suite never runs and no workspace
# is pinned — the self-skip against release.metadata["qa_gates"] (ship_gate_skip?)
# went with the local suite it used to spare.
#
# WHY THIS FILE EXISTS SEPARATELY. test/lib/release_cli_test.rb owns the ship lane's
# integration coverage and is the suite's worst APPEND hotspot — frozen at its ceiling
# in config/test_health.yml by design. The ratchet's stated out is a new file named
# for its concern, which is what this is; `run_cli` and the canned git stub are
# re-implemented from it rather than shared, as test/lib/release_pre_qa_remedy_test.rb
# does, so loading this file never loads that one's 290 tests.
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseShipGateReadTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The frozen ship SHA under test (what a stubbed `git rev-parse` answers), a
  # DISTINCT accepted head, and the tree the two share in the same-tree rows.
  GATE_SHA    = "f00dcafe11111111111111111111111111111111"
  ACC_SHA     = "acce97ed22222222222222222222222222222222"
  SHARED_TREE = "5b1c78e033333333333333333333333333333333"

  # The same-SHA credit shape (CiStatus.credit_for_sha): the accepted seam's suite
  # concluded green, and the release push queued duplicate runs of the SAME check
  # names — G3's credit payload, verbatim.
  CREDIT_PAYLOAD = '{"total_count":4,"check_runs":[' \
                   '{"name":"test","status":"completed","conclusion":"success"},' \
                   '{"name":"test:system","status":"completed","conclusion":"success"},' \
                   '{"name":"test","status":"queued","conclusion":null},' \
                   '{"name":"test:system","status":"in_progress","conclusion":null}]}'

  # The gate's git plumbing, canned — verbatim from release_cli_test.rb's
  # GATE_GIT_STUB: rev-parse → GATE_SHA, workspace git → ok, the private-DB probe
  # answered as a compliant app would. Every stub below answers `origin/accepted` and
  # the two `^{tree}` reads BEFORE falling through to it.
  GATE_GIT_STUB = <<~RUBY
    GATE_SHA = #{GATE_SHA.inspect}
    def gate_git(a, k)
      return [GATE_SHA, true] if a[0] == "git" && a.include?("rev-parse")
      return ["", true] if a[0] == "git" && %w[fetch worktree reset clean].include?(a[3].to_s)
      if a[0] == "bin/rails" && a[1] == "runner"
        url = k[:env].to_h["DATABASE_URL"].to_s
        db  = url.empty? ? File.join(k[:chdir].to_s, "storage", "test.sqlite3") : url.split("/").last
        return ["GATEDB=" + db, true]
      end
      return ["", true] if a[0] == "bin/rails" && a[1] == "db:test:prepare"
      nil
    end
  RUBY

  # Every subprocess here loads bin/release.rb standalone, session-less (SessionEnv) and
  # with the outbound seams sealed (OutboundSeams: `gh` / `heroku` / `op` resolve to
  # logging stubs, never the real binaries) — the same floor release_cli_test.rb's
  # run_ruby lays. The lock dir is isolated per run so no child touches the live
  # conductor's locks; TASK_API_BASE is unroutable so no board write can leave the box.
  def run_cli(argv, call:, setup: "")
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; #{call})
    Dir.mktmpdir("release-ship-gate-read-locks") do |locks|
      env = OutboundSeams.env(
        "MCR_PRIMARY_LOCK_DIR" => locks,
        "SEAL_RETRY_DELAY_SECONDS" => "0",
        "TASK_API_BASE" => "http://127.0.0.1:1"
      )
      out, err, status = Open3.capture3(env, "ruby", "-e", script)
      return out if status.success?

      flunk "bin/release subprocess exited #{status.exitstatus.inspect}\nstdout=#{out.inspect}\nstderr:\n#{err}"
    end
  end

  # --- G4 ship gate: the tree-verdict READ on the FROZEN SHA (devops-v3 §5) --------
  #
  # One tree earns one verdict. test_gate resolves the frozen ship SHA through the SAME
  # credit-or-poll path G3 runs on the release tip (resolve_release_ci_verdict) and
  # classifies what it read (Release::ShipSequence.ship_gate_kind — the pure state table
  # is unit-tested there; THIS is the wiring). These drive the REAL test_gate with
  # injected verdicts and a stubbed git, one case per row: green (its own run), credited
  # same-SHA, credited same-tree, red, held past the poll bound (pending / none /
  # unverified), unreadable, diverged. In EVERY row the local suite never runs, and no
  # G3 record is consulted — the self-skip against release.metadata["qa_gates"]
  # (ship_gate_skip?) went with the local suite it used to spare.
  #
  # `accepted:` is what `git rev-parse origin/accepted` answers (GATE_SHA = the frozen
  # SHA IS the accepted head, a fast-forward; ACC_SHA = a distinct head); the two
  # `*_tree:` values decide tree identity; `verdicts` maps a SHA to the ci_verdict Hash
  # it answers, and `ci_status` injects RELEASE_CI_STATUS (a token, or the same-SHA
  # credit payload). The poll window is collapsed to ONE read, so a pass on a pending
  # own-run can ONLY come from a credit.
  def ship_read_stub(dir, accepted: GATE_SHA, accepted_tree: SHARED_TREE, frozen_tree: SHARED_TREE,
                     ci_status: nil, verdicts: nil)
    env = ci_status ? %(ENV["RELEASE_CI_STATUS"] = #{ci_status.inspect}\n) : ""
    verdict_def = verdicts ? %(def ci_verdict(_repo, sha) = #{verdicts.inspect}.fetch(sha) { { state: :none } }\n) : ""
    env +
      %(ENV["RELEASE_CI_POLL_TIMEOUT"] = "0"\nENV["RELEASE_CI_POLL_INTERVAL"] = "0"\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB +
      %(ACC_SHA = #{ACC_SHA.inspect}\n) +
      %(def app_meta_for(_repo) = { "test_cmd" => "bin/suite" }\n) +
      verdict_def +
      %(def sh(*a, **k)\n) +
      %(  $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"\n) +
      %(  $stdout.puts("WORKSPACE \#{a[3]}") if a[0] == "git" && %w[worktree reset clean].include?(a[3].to_s)\n) +
      %(  return [#{accepted.inspect}, true] if a.include?("origin/accepted")\n) +
      %(  return [#{frozen_tree.inspect}, true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
      %(  return [#{accepted_tree.inspect}, true] if a.last.to_s == ACC_SHA + "^{tree}"\n) +
      %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)
  end

  # Drive the real test_gate on the frozen GATE_SHA, printing the SOP buffer and either
  # PASSED or the abort text.
  def run_ship_read(setup)
    run_cli(["--yes"], setup: setup,
                       call: %{$gate_sops = []; begin; test_gate("x", frozen_sha: #{GATE_SHA.inspect}); puts("PASSED"); } +
                             %{rescue SystemExit => e; puts("ABORTED: " + e.message); end; puts("SOPS " + $gate_sops.inspect)})
  end

  def ship_read_sops(out)
    out.lines.find { |l| l.start_with?("SOPS") } || flunk("the gate must record a SOP either way: #{out}")
  end

  # [integration] GREEN, ITS OWN RUN: the frozen tree shares nothing with the accepted
  # head (no credit possible), so the verdict is the SHA's own run — read green, the gate
  # PASSES, and the SOP names that source. Nothing ran here.
  def test_ship_test_gate_passes_on_the_frozen_shas_own_green_run
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, accepted: ACC_SHA, accepted_tree: "2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b",
                                              frozen_tree: "1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",
                                              verdicts: { GATE_SHA => { state: :green, count: 8 } }))

      assert_includes out, "GitHub CI verdict for frozen #{GATE_SHA[0, 7]}", "the gate reads CI for the frozen SHA"
      assert_includes out, "shares neither SHA nor tree", "the non-credit is NAMED before the own run is polled"
      sops = ship_read_sops(out)
      assert_includes sops, %("sop"=>"ship_test_gate")
      assert_includes sops, %("result"=>"pass")
      assert_includes sops, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}"
      assert_includes sops, "the SHA's own run, polled to a settled conclusion", "…naming the verdict's SOURCE"
      assert_includes sops, "bin/suite ran in CI, not here", "…and the suite CI ran"
      refute_includes out, "SUITE-RAN", "the local suite never runs — CI is the verdict"
      refute_includes out, "WORKSPACE", "the read pins no workspace"
      assert_includes out, "PASSED"
    end
  end

  # [integration] CREDITED, SAME SHA: the frozen SHA IS the accepted head (a fast-forward
  # promote) and already carries completed greens that cover the pending duplicates —
  # exactly G3's same-SHA credit (CiStatus.credit_for_sha). With the poll collapsed, a
  # PASS can only come from that credit, and the SOP names it as the source.
  def test_ship_test_gate_credits_the_frozen_shas_own_completed_greens_on_a_fast_forward
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, accepted: GATE_SHA, ci_status: CREDIT_PAYLOAD))

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}"
      sops = ship_read_sops(out)
      assert_includes sops, %("result"=>"pass")
      assert_includes sops, "GitHub CI GREEN @ #{GATE_SHA[0, 7]} — credited — ", "the SOP names a CREDITED source"
      assert_includes sops, "completed check-run", "…the completed runs that covered the duplicates"
      assert_includes sops, "fast-forward promote", "…and why the credit applied"
      refute_includes out, "SUITE-RAN"
      assert_includes out, "PASSED"
    end
  end

  # [integration] CREDITED, SAME TREE: the frozen SHA is a batch-PR merge commit whose
  # tree equals the accepted head's, and the accepted head's own run is green — G3's
  # tree credit (tree_identical_ci_outcome), now vouching for the frozen tree at ship.
  # The frozen SHA's own run reads PENDING and the poll is collapsed, so the credit is
  # the only way to pass; the SOP names both SHAs and the shared tree.
  def test_ship_test_gate_credits_the_accepted_heads_green_for_an_identical_frozen_tree
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, accepted: ACC_SHA, accepted_tree: SHARED_TREE, frozen_tree: SHARED_TREE,
                                              verdicts: { ACC_SHA => { state: :green, count: 8 },
                                                          GATE_SHA => { state: :pending } }))

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}"
      sops = ship_read_sops(out)
      assert_includes sops, %("result"=>"pass")
      assert_includes sops, "credited — tree-identical promote", "the SOP names the tree credit as the source"
      assert_includes sops, ACC_SHA, "…the accepted head that vouched"
      assert_includes sops, SHARED_TREE, "…and the shared tree"
      refute_includes out, "SUITE-RAN"
      assert_includes out, "PASSED"
    end
  end

  # [integration] RED FAILS CLOSED: a failed check on the frozen SHA aborts BEFORE the
  # irreversible prod deploy, names the red, and records a RED SOP.
  def test_ship_test_gate_fails_closed_on_a_red_ci_verdict
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, ci_status: "red"))

      assert_includes out, "ABORTED", "a red frozen SHA must abort BEFORE the prod deploy"
      assert_includes out, "called frozen #{GATE_SHA[0, 7]} RED", "…naming CI's red verdict for the frozen SHA"
      assert_includes out, "must not ship"
      assert_includes ship_read_sops(out), %("result"=>"fail"), "the red gate is recorded as a failed SOP"
      refute_includes out, "SUITE-RAN"
      refute_includes out, "PASSED"
    end
  end

  # [integration] HELD PAST THE POLL BOUND: a pending / absent / unverified verdict for
  # the frozen SHA is polled (here: bound 0, one read) and then fails CLOSED — it HOLDS
  # the ship, names what it read and how long it polled, points at the override, and
  # never reads as a pass. (A red-CI abort names "RED"; these must not.)
  def test_ship_test_gate_holds_on_a_verdict_that_never_settled_within_the_poll_bound
    %w[pending none unverified].each do |state|
      Dir.mktmpdir do |dir|
        out = run_ship_read(ship_read_stub(dir, ci_status: state))

        assert_includes out, "ABORTED", "#{state}: an absent/unsettled CI verdict must fail the ship gate closed"
        assert_includes out, "test gate HELD", "#{state}: a hold, not a red"
        assert_includes out, "NO green verdict for frozen #{GATE_SHA[0, 7]} (#{state}", "#{state}: names what it read"
        assert_includes out, "after polling ~0s", "#{state}: …and that it polled to the bound"
        assert_includes out, "FAILS CLOSED", "#{state}: says why it held"
        assert_includes out, "--skip-test-gate", "#{state}: points at the first-class override"
        assert_includes ship_read_sops(out), %("result"=>"fail"), "#{state}: a hold is recorded as a failed SOP"
        refute_includes out, "SUITE-RAN", "#{state}: no local suite runs"
        refute_includes out, "PASSED"
      end
    end
  end

  # [integration] UNREADABLE aborts AT ONCE: a refused read (401/403) is a token fault
  # polling cannot heal, so the gate does not poll it — it names the fault and the
  # credential remedy, and never trades the silence for a green.
  def test_ship_test_gate_aborts_at_once_on_an_unreadable_ci_verdict
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, ci_status: "unreadable"))

      assert_includes out, "ABORTED"
      assert_includes out, "GitHub CI is UNREADABLE for frozen #{GATE_SHA[0, 7]}", "names the fault, not a hold"
      assert_includes out, "did NOT poll it", "a refused token is not waited on"
      assert_includes out, "credential/token fault"
      assert_includes out, "--skip-test-gate"
      refute_includes out, "test gate HELD", "unreadable is not the pending class"
      assert_includes ship_read_sops(out), %("result"=>"fail")
      refute_includes out, "SUITE-RAN"
      refute_includes out, "PASSED"
    end
  end

  # [integration] DIVERGED: the frozen tree shares neither SHA nor tree with the accepted
  # head (a consumer lock-bump commit, or accepted has moved on), so no earlier green can
  # vouch for it — AND its own run gave no green within the bound. The abort names BOTH
  # halves, so the operator knows why no credit applied and what the own run read.
  def test_ship_test_gate_names_a_diverged_tree_whose_own_run_never_went_green
    Dir.mktmpdir do |dir|
      out = run_ship_read(ship_read_stub(dir, accepted: ACC_SHA, accepted_tree: "2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b",
                                              frozen_tree: "1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",
                                              verdicts: { GATE_SHA => { state: :pending } }))

      assert_includes out, "ABORTED"
      assert_includes out, "shares neither SHA nor tree with the accepted head", "names why no credit applied"
      assert_includes out, "no earlier green could vouch for its tree"
      assert_includes out, "OWN run has NO green verdict for frozen #{GATE_SHA[0, 7]} (pending)", "…and what the own run read"
      assert_includes out, "FAILS CLOSED"
      assert_includes out, "--skip-test-gate"
      refute_includes out, "crediting", "a diverged tree credits nothing"
      assert_includes ship_read_sops(out), %("result"=>"fail")
      refute_includes out, "SUITE-RAN"
      refute_includes out, "PASSED"
    end
  end

  # [integration] The read consults NO G3 record. A release whose qa_gates carry a green,
  # matching certification used to make G4 self-skip; now the frozen SHA's own CI verdict
  # decides regardless — a RED frozen SHA aborts even beside a "certified green" record,
  # because the record is an audit trail, not a verdict.
  def test_ship_test_gate_ignores_the_g3_record_and_reads_ci_for_the_frozen_tree
    Dir.mktmpdir do |dir|
      setup = ship_read_stub(dir, ci_status: "red") +
              %(\ndef conductor(_ruby, read_only: false) = { "qa_gates" => { "x" => { "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true } } }\n)
      out = run_ship_read(setup)

      assert_includes out, "ABORTED", "a green G3 record cannot pass a frozen SHA CI calls red"
      assert_includes out, "called frozen #{GATE_SHA[0, 7]} RED"
      refute_includes out, "already CERTIFIED", "there is no self-skip to print"
      refute_includes out, "PASSED"
    end
  end

end

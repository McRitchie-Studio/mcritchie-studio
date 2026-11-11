# frozen_string_literal: true

# The pre-QA gate's credit from any ref (task release-sub-hour-pipeline): a same-SHA
# green from another ref, a green that concludes while the gate holds, and a green on
# an identical tree (the accepted head or a merged PR head). Run directly:
#   ruby -Itest test/lib/release_cli_gate_credit_test.rb

require_relative "release_cli_harness"

class ReleaseCliGateCreditTest < ReleaseCliHarness
  DIVERGED_GIT = %(\ndef sh(*a, **k)\n) +
                 %(  return ["2222222222222222222222222222222222222222", true] if a.include?("origin/accepted")\n) +
                 %(  return ["1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a", true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
                 %(  return ["2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b", true] if a.last.to_s.end_with?("^{tree}")\n) +
                 %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)

  # [integration] SAME SHA, ANY BRANCH (task release-sub-hour-pipeline, acceptance 1).
  # The SHA's own record holds a completed green whose pending runs only duplicate it,
  # and origin/release is NOT the accepted head. The commit is the same content
  # whichever ref earned the green, so the gate credits it without the fast-forward
  # precondition and names the source as another ref.
  def test_pre_qa_gate_credits_a_same_sha_green_from_any_branch
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD) + DIVERGED_GIT,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}"
      assert_includes out, "same SHA, earned on another ref", "the note says the green came from another ref"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}"
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE 2a2430c HOLD (rel-20261110-0123f9). origin/release IS the accepted
  # head, and at the first read both push runs are in flight, so no credit exists yet.
  # The accepted run then concludes green while the release duplicate is still queued.
  # The poll re-asks for the credit on its held reads and passes on the second, without
  # waiting out the duplicate: the SHA's own fold stays :pending to the end.
  def test_pre_qa_gate_credits_a_green_that_concludes_while_it_holds
    Dir.mktmpdir do |dir|
      setup = ci_gate_stub(dir, "unused") + <<~'RUBY'
        ENV["RELEASE_CI_POLL_TIMEOUT"] = "30"
        ENV["RELEASE_CI_CREDIT_INTERVAL"] = "0"
        $reads = 0
        def ci_verdict(_repo, _sha) = { state: :pending, pending: ["test"] }
        def ci_credit_verdict(_repo, _sha)
          $reads += 1
          return nil if $reads < 3
          { state: :green, count: 2, credited: "2 completed check-runs already green" }
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("READS=" + $reads.to_s); puts("PASSED")})

      assert_includes out, "re-checking for a credit on every read", "the first decline says the poll keeps asking"
      assert_includes out, "concluded while this gate was holding", "the credit names when it fired"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}"
      assert_includes out, "READS=3", "one probe before the poll, then one per held read until the green"
      refute_includes out, "poll timed out"
      assert_includes out, "PASSED"
    end
  end

  # [unit] RED STILL ABORTS: a red held on this SHA while its run is in progress is never
  # credited away by an identical-tree green; the poll waits for the red to settle.
  def test_a_red_held_on_the_sha_never_asks_for_a_credit
    setup = %(ENV["RELEASE_CI_POLL_INTERVAL"] = "0"\n$probes = 0\n) +
            %(def ci_verdict(_r, _s) = { state: :red, failing: ["test"] }\n) +
            %(def ci_red_once!(_r, _s) = :pending\n)
    call = %(c = poll_ci_verdict("r", "abc1234", budget: 0.2, credit: -> { $probes += 1; { state: :green, credited: "x" } }); ) +
           %(print [c[:state], $probes].inspect)
    assert_equal "[:red, 0]", run_cli(["--dry-run"], setup: setup, call: call).lines.last
  end

  # [unit] identical_tree_candidates — the other refs whose tree IS this SHA's tree:
  # the accepted head and the PR head a merge joined (the second parent). A candidate
  # with another tree, the SHA itself, and every git fault are dropped.
  def test_identical_tree_candidates_finds_the_accepted_and_pr_heads_with_the_same_tree
    git = %(def swept_pin(_r) = ""\n) +
          %(def sh(*a, **_k)\n) +
          %(  last = a.last.to_s\n) +
          %(  return ["acc0", true] if last == "origin/accepted"\n) +
          %(  return ["prhead", true] if last == "rel^2"\n) +
          %(  return ["", ENV["STALE_BASE"].nil?] if a.include?("--is-ancestor")\n) +
          %(  return ["", false] if last.end_with?("^2")\n) +
          %(  return ["other-tree", true] if last == "acc0^{tree}"\n) +
          %(  return ["T1", true] if last.end_with?("^{tree}")\n) +
          %(  ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: git, call: %(print identical_tree_candidates("/x", "rel", repo: "r").inspect))
    assert_equal %([["prhead", "T1"]]), out, "the PR head shares the tree; the accepted head does not"

    out = run_cli(["--dry-run"], setup: %(ENV["STALE_BASE"] = "1"\n) + git,
                  call: %(print identical_tree_candidates("/x", "rel", repo: "r").inspect))
    assert_equal "[]", out, "a PR head whose base was not in it tested another tree: no candidate"

    failed = %(def swept_pin(_r) = ""\ndef sh(*a, **_k) = ["", false]\n)
    out = run_cli(["--dry-run"], setup: failed, call: %(print identical_tree_candidates("/x", "rel").inspect))
    assert_equal "[]", out, "a git fault offers no candidate, never an abort"
  end

  # [unit] credit_on_poll credits only a GREEN identical-tree candidate; a red or
  # pending candidate, or none at all, keeps the poll holding.
  def test_credit_on_poll_credits_only_a_green_identical_tree
    base = %(def ci_credit_verdict(_r, _s) = nil\n) +
           %(def identical_tree_candidates(_p, _s, repo: nil) = [["prhead", "T1"]]\n)
    out = run_cli(["--dry-run"], setup: base + %(def ci_verdict(_r, _s) = { state: :green, count: 9 }\n),
                  call: %(c = credit_on_poll("r", "/x", "rel"); print [c[:state], c[:credited]].inspect))
    assert_includes out, ":green"
    assert_includes out, "identical tree T1 — prhead concluded green"

    %i[red pending none unreadable].each do |state|
      out = run_cli(["--dry-run"], setup: base + %(def ci_verdict(_r, _s) = { state: #{state.inspect} }\n),
                    call: %(print credit_on_poll("r", "/x", "rel").inspect))
      assert_equal "nil", out, "#{state}: a non-green candidate credits nothing"
    end
  end
end

# frozen_string_literal: true

# [integration] The `docs` shape is EARNED FROM THE DIFF, not typed
# (/tasks/docs-shape-admits-test-code). Standalone — no Rails; it shells bin/dor-check
# with --file fixtures:
#   ruby -Itest test/lib/dor_check_docs_shape_test.rb
#
# THE BUG. `shape: docs` carries zero tiers AND `full_suite_gate: false`, and until this
# landed both were unlocked by TYPING `docs`. The diff was never consulted, so a
# docs-claimed change carrying executable code shipped with no tier and no cert demanded.
#
# OBSERVED, not reasoned about. PR #1172 (shape docs) carried test/integration/
# open_pr_receipt_visibility_test.rb and dor-check printed "✓ DoR-to-Merge met",
# demanding nothing. That PR was well-certified ANYWAY, by a builder who supplied
# evidence the gate never asked for — which is the failure mode rather than the
# mitigation: a gate satisfied by volunteered evidence holds for careful builders and
# fails silently for everyone else.
#
# WHAT MADE IT SURVIVE was a fall-through, and these tests pin the seam it fell through.
# The exempt-KIND gate already asks this exact question on this exact diff and already
# refuses — then hands control to the shape contract, which granted the same exemption
# one step later. Two answers, one question. So the claim guard reuses CodeDiff, the
# classifier the kind gate runs, rather than a second prose list that could drift apart.
#
# NOT fixed by `full_suite_gate: true` on docs, deliberately: that would make every prose
# correction pay a full suite, and push people to mislabel shapes — strictly worse than
# the hole. Gate the CLAIM, not the cost.
#
# ITS OWN FILE, on purpose. test/lib/dor_check_test.rb is a named APPEND HOTSPOT in
# config/test_health.yml, and appending here first pushed it 201 lines past its ceiling
# and turned CI red. The ratchet's advice is the house rule and it is right: a new
# concern gets a new file named for it.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class DorCheckDocsShapeTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  # The session scrub plus the network floor — the child must not reach GitHub, `op`,
  # or the board. See dor_check_test.rb's dor_env for what that floor closed (a plain
  # `bin/rails test` minting real App installation tokens against fixture PR URLs).
  def dor_env(overrides = {})
    OutboundSeams.env(overrides)
  end

  # Runs dor-check against an in-memory devops payload, returns [output, exitcode].
  # STDOUT only: under `bin/rails test` the subprocess inherits bundler's env and emits
  # rubygems warnings on STDERR, which would corrupt a --json parse if merged.
  def check(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      with_default_suite_evidence do
        with_neutralized_pr_read do
          out = IO.popen(dor_env, "#{BIN} --file #{path} #{args.join(' ')} 2>/dev/null", &:read)
          [out, $?.exitstatus]
        end
      end
    end
  end

  # The merge gate demands fingerprint-bound full-suite evidence for a shaped feature.
  # Default it fresh-green so these tests stay about the CLAIM guard, not the cert.
  def with_default_suite_evidence
    had = ENV.key?("DOR_CHECK_SUITE_EVIDENCE")
    ENV["DOR_CHECK_SUITE_EVIDENCE"] = "ok" unless had
    yield
  ensure
    ENV.delete("DOR_CHECK_SUITE_EVIDENCE") unless had
  end

  # "" is the seam's "the PR listed no files" — so the LOCAL diff path is what these
  # tests measure, and no fixture URL is ever fetched.
  def with_neutralized_pr_read
    had = ENV.key?("DOR_CHECK_PR_FILES")
    ENV["DOR_CHECK_PR_FILES"] = "" unless had
    yield
  ensure
    ENV.delete("DOR_CHECK_PR_FILES") unless had
  end

  # Inject a deterministic branch diff. `files` is newline separated; "" means "no diff".
  def with_changed_files(files)
    had = ENV.key?("DOR_CHECK_CHANGED_FILES")
    prev = ENV["DOR_CHECK_CHANGED_FILES"]
    ENV["DOR_CHECK_CHANGED_FILES"] = files
    yield
  ensure
    had ? (ENV["DOR_CHECK_CHANGED_FILES"] = prev) : ENV.delete("DOR_CHECK_CHANGED_FILES")
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # A throwaway git repo so the script's REAL changed_files git path runs (injection
  # OFF). Base is HEAD, so the committed view is empty — the pre-commit SOP case.
  def with_git_repo(untracked: [])
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m init")
      untracked.each do |rel|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "new\n")
      end
      yield dir
    end
  end

  def check_against(dir, devops, *args)
    with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil) do
      check(devops, *args)
    end
  end

  # `test-only` is the sibling zero-tier shape, used below to prove the waiver line
  # tells the truth about each half INDEPENDENTLY.
  TEST_ONLY_CONTRACT = {
    "shape" => "test-only", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["tests"], "acceptance" => ["Stale assertion no longer misleads"],
    "test_plan" => ["control"], "post_deploy_cmd" => "none",
    "checks_run" => ["[control] pre-change test/integration/hub_test.rb at HEAD → 1 failure at line 42"]
  }.freeze

  TEST_ONLY_DIFF = "test/integration/hub_test.rb\ntest/test_helper.rb\ne2e/helpers.js"

  # A `docs` submission that is honest: prose only, everything the shape asks for.
  # `kind` is deliberately NOT chore/cleanup/docs — an exempt kind short-circuits on
  # a doc-only diff long before the shape contract, so these tests would be grading
  # the kind gate instead of the shape guard they are about.
  DOCS_CONTRACT = {
    "kind" => "bug", "shape" => "docs", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["docs"], "acceptance" => ["Runbook names the correct command"],
    "test_plan" => ["prose review"], "post_deploy_cmd" => "none"
  }.freeze

  def test_integration_docs_passes_on_a_prose_only_diff
    out, code = with_changed_files("docs/agents/note.md\nREADME.md") { check(DOCS_CONTRACT) }

    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  # THE REGRESSION, verbatim: PR #1172's diff. A doc change that also repairs one
  # test file is the ORDINARY doc task, which is why this was reachable without
  # anyone doing anything unusual.
  def test_integration_docs_is_refused_when_the_diff_carries_a_test_file
    out, code = with_changed_files("docs/agents/note.md\ntest/integration/open_pr_receipt_visibility_test.rb") do
      check(DOCS_CONTRACT)
    end

    refute_equal 0, code,
                 "a docs-claimed diff carrying a TEST FILE was told DoR-to-Merge met — this is PR #1172, " \
                 "and the shape's zero tiers plus waived suite cert were granted on a typed label\n#{out}"
    assert_match(%r{test/integration/open_pr_receipt_visibility_test\.rb}, out,
                 "the refusal must NAME the disqualifying file, or the builder is told 'something' was wrong")
    assert_match(/may only be claimed on a diff that is ENTIRELY prose/, out)
  end

  # The filing recorded a test file, but nothing about the hole was specific to
  # tests: production code rode it identically. Pinning this separately, because a
  # fix scoped to `test/` would pass the test above and leave the larger hole open.
  def test_integration_docs_is_refused_when_the_diff_carries_production_code
    out, code = with_changed_files("docs/agents/note.md\napp/models/task.rb") { check(DOCS_CONTRACT) }

    refute_equal 0, code, out
    assert_match(%r{app/models/task\.rb}, out)
  end

  # The three edges config/feature_shapes.yml PROMISES the next reader, pinned at
  # the gate so the written rule cannot quietly become false.
  def test_integration_docs_is_refused_on_a_comment_only_config_edit
    # The granularity is the FILE, never the hunk. A .yml edit may well be nothing
    # but comments; deciding that requires a parse an author can talk the gate out
    # of, so the strict answer stands and costs one tier line on another shape.
    out, code = with_changed_files("docs/agents/note.md\nconfig/e2e_lane.yml") { check(DOCS_CONTRACT) }

    refute_equal 0, code, out
    assert_match(%r{config/e2e_lane\.yml}, out)
  end

  def test_integration_docs_is_refused_on_an_executable_filed_under_docs
    # LOCATION BUYS NOTHING: docs/agents/setup.sh is mode 100755.
    out, code = with_changed_files("docs/agents/setup.sh") { check(DOCS_CONTRACT) }

    refute_equal 0, code, out
    assert_match(%r{docs/agents/setup\.sh}, out)
  end

  # Fail-closed, mirroring the exempt-kind gate and the test-only claim: "we saw
  # nothing" is not "there is nothing but prose".
  def test_integration_docs_is_refused_when_no_diff_can_be_observed
    out, code = with_changed_files("") { check(DOCS_CONTRACT) }

    refute_equal 0, code, out
    assert_match(/could not be proven doc-only/, out)
    assert_match(/fail-closed/, out)
  end

  # The build gate stays lenient on an EMPTY diff (at design time no code exists
  # yet, and it enforces no tiers either way) …
  def test_integration_docs_at_the_build_gate_survives_an_empty_diff
    out, code = with_changed_files("") { check(DOCS_CONTRACT, "--gate", "build") }

    assert_equal 0, code, out
  end

  # … but an OBSERVABLE build-gate diff carrying code still errors, because the
  # earlier the shape is corrected the less work is thrown away.
  def test_integration_docs_at_the_build_gate_still_refuses_an_observed_code_diff
    out, code = with_changed_files("app/models/task.rb") { check(DOCS_CONTRACT, "--gate", "build") }

    refute_equal 0, code, out
    assert_match(%r{app/models/task\.rb}, out)
  end

  # ==== against a REAL git tree, not the injection seam ================================
  # DOR_CHECK_CHANGED_FILES is a test seam, and a guard proven only through its own
  # seam is proven against a proxy. This runs dor-check over an actual working tree,
  # so the claim covers the production path: git → CodeDiff.paths_from_name_status →
  # CodeDiff.code_files. If the wiring between them broke, every seam test above
  # would still pass.
  def test_integration_docs_is_refused_by_a_real_tree_carrying_a_test_file
    with_git_repo(untracked: ["docs/agents/note.md", "test/models/thing_test.rb"]) do |dir|
      out, code = check_against(dir, DOCS_CONTRACT)

      refute_equal 0, code,
                   "a REAL working tree carrying test/models/thing_test.rb claimed the docs shape — the seam " \
                   "tests pass but the production path does not consult the classifier\n#{out}"
      assert_match(%r{test/models/thing_test\.rb}, out)
    end
  end

  def test_integration_docs_passes_on_a_real_prose_only_tree
    with_git_repo(untracked: ["docs/agents/note.md"]) do |dir|
      out, code = check_against(dir, DOCS_CONTRACT)

      assert_equal 0, code, out
    end
  end

  # ==== [integration] THE WAIVER SAYS ITS OWN NAME ====================================
  #
  # The second half of the filing, and the half that would have surfaced the bug
  # without anyone hunting for it. A gate that skips a requirement in SILENCE reads
  # exactly like a gate that enforced one and passed: on PR #1172 the verdict was
  # "✓ DoR-to-Merge met (shape: docs)" and a blank line where the tier line goes.
  # Nothing said a tier was skipped, nothing said the cert was waived, and nothing
  # said whether the shape had been checked against the diff at all.
  def test_integration_a_waived_tier_and_cert_are_named_in_the_verdict
    out, code = with_changed_files("docs/agents/note.md") { check(DOCS_CONTRACT) }

    assert_equal 0, code, out
    assert_match(/no test tier required/, out,
                 "a skipped tier requirement must NAME itself; silence is what let the docs hole survive " \
                 "every reader who had already seen this output")
    assert_match(/full-suite cert waived/, out)
    assert_match(/claim verified against the OBSERVED diff \(doc_only_diff/, out,
                 "the reader's question is 'was this checked?' — only a printed answer distinguishes " \
                 "'verified against the diff' from 'nobody asked'")
  end

  # The waiver line must tell the TRUTH about each half independently. `test-only`
  # also has zero tiers, and its full-suite cert is emphatically NOT waived — a line
  # that said so would be a new false statement replacing a silent one.
  def test_integration_the_waiver_line_does_not_claim_test_only_skips_the_suite
    out, code = with_changed_files(TEST_ONLY_DIFF) { check(TEST_ONLY_CONTRACT) }

    assert_equal 0, code, out
    assert_match(/no test tier required/, out)
    refute_match(/full-suite cert waived/, out,
                 "test-only DEMANDS the full-suite cert (test code is code, and it is the change most able " \
                 "to break the suite quietly) — announcing a waiver here would be a fresh lie")
  end

  # A shape that owes tiers gets no waiver line at all, or the line becomes noise
  # that readers learn to skip — which is how it would stop working.
  def test_integration_a_fully_gated_shape_prints_no_waiver_line
    out, code = with_changed_files("app/models/task.rb") do
      check("shape" => "backend", "repositories" => ["mcritchie-studio"], "risk_tags" => ["x"],
            "acceptance" => ["The gate demands both tiers"], "test_plan" => %w[unit integration],
            "post_deploy_cmd" => "none", "checks_run" => ["[unit] a", "[integration] b"])
    end

    assert_equal 0, code, out
    refute_match(/no test tier required/, out)
    refute_match(/full-suite cert waived/, out)
  end

  # The build gate zeroes dor_tiers for EVERY shape by design (tiers are build
  # artifacts, unknowable at design time), so a waiver line there would fire on every
  # task and say nothing true about the shape.
  def test_integration_the_build_gate_prints_no_waiver_line
    out, code = with_changed_files("docs/agents/note.md") { check(DOCS_CONTRACT, "--gate", "build") }

    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out,
                 "this must reach a READY verdict, or it is asserting the absence of a line that was never " \
                 "going to print — an inert check dressed as a guard")
    refute_match(/no test tier required/, out)
  end
end

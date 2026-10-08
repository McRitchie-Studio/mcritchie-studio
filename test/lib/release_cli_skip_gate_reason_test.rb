# frozen_string_literal: true

# `bin/release ship --skip-test-gate --reason`: one reason serves every gated repo.
#
# Run directly:
#   ruby -Itest test/lib/release_cli_skip_gate_reason_test.rb

require_relative "release_cli_harness"

class ReleaseCliSkipGateReasonTest < ReleaseCliHarness
  # [unit] The gate runs once per gated repo; every one of them reads the reason.
  def test_skip_test_gate_keeps_its_reason_for_every_gated_repo
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + SKIP_GATE_STUB
      call = %{$gate_sops = []; begin; %w[x y].each { |r| test_gate(r, frozen_sha: #{GATE_SHA.inspect}) }; } +
             %{puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end}
      out = run_cli(["--yes", "--skip-test-gate", "--reason", "rails_plan never settles"], setup: setup, call: call)

      refute_includes out, "requires --reason", "the second repo must still see the reason: #{out}"
      assert_includes out, "SKIPPED BY OPERATOR for x (--skip-test-gate) — rails_plan never settles"
      assert_includes out, "SKIPPED BY OPERATOR for y (--skip-test-gate) — rails_plan never settles"
      assert_includes out, "PASSED"
    end
  end
end

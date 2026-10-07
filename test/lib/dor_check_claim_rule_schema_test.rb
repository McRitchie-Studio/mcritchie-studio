# frozen_string_literal: true

# Guard catalog row 2.6: bin/dor-check checks config/feature_shapes.yml's
# `claimable_when` rules against CLAIM_RULES when the config loads, so an
# unimplemented rule is a config error named before any task is read, and the
# per-task "unclassified claim rule" refusal is gone. Run directly:
#   ruby -Itest test/lib/dor_check_claim_rule_schema_test.rb

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../support/session_env"

class DorCheckClaimRuleSchemaTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SHAPES = File.expand_path("../../config/feature_shapes.yml", __dir__)

  def run_with_config(config)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "feature_shapes.yml")
      File.write(path, config.to_yaml)
      env = SessionEnv.neutralized.merge("DOR_CHECK_SHAPES_CONFIG" => path)
      out = IO.popen(env, [BIN, "some-task", "--file", File.join(dir, "missing.json"), { err: [:child, :out] }], &:read)
      [out, $?.exitstatus]
    end
  end

  def test_an_unimplemented_claim_rule_fails_at_load_before_any_task_is_read
    config = YAML.safe_load(File.read(SHAPES))
    config["shapes"]["docs"]["claimable_when"] = "made_up_diff"

    out, code = run_with_config(config)

    assert_equal 2, code, out
    assert_includes out, "docs: made_up_diff"
    assert_includes out, "does not implement"
  end

  def test_the_committed_config_passes_the_load_check
    out, code = run_with_config(YAML.safe_load(File.read(SHAPES)))

    refute_includes out, "does not implement"
    refute_equal 2, code, out
  end
end

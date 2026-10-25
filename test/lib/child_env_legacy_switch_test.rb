# frozen_string_literal: true

# [unit] ChildEnv.renewer keeps AgentApi's shared-token OFF switch and nothing else
# under that name (secrets-scrub-review-notes).
#
# ChildEnv copies AgentApi::LEGACY_ENV and LEGACY_OFF so child_env.rb stays
# loadable on its own (bin/dev execs it as a script). This test pins the copies
# equal, so a new OFF spelling added to AgentApi cannot silently fall back to the
# shared token in every detached renewer.
#
#   ruby -Itest test/lib/child_env_legacy_switch_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/child_env"
require_relative "../../bin/lib/agent_api"

class ChildEnvLegacySwitchTest < Minitest::Test
  def test_the_copied_switch_matches_agent_api
    assert_equal AgentApi::LEGACY_ENV, ChildEnv::LEGACY_SWITCH
    assert_equal AgentApi::LEGACY_OFF.sort, ChildEnv::LEGACY_SWITCH_OFF.sort
  end

  def test_every_off_spelling_passes_to_a_renewer
    (ChildEnv::LEGACY_SWITCH_OFF + [" OFF ", "False"]).each do |value|
      kept = ChildEnv.renewer({}, { "AGENT_LEGACY_TOKEN" => value })
      assert_equal value, kept["AGENT_LEGACY_TOKEN"], "#{value.inspect} did not pass"
    end
  end

  def test_any_other_value_is_dropped
    ["on", "1", "", "sk-live-pasted-token"].each do |value|
      refute ChildEnv.renewer({}, { "AGENT_LEGACY_TOKEN" => value }).key?("AGENT_LEGACY_TOKEN"), value.inspect
    end
  end

  def test_a_launcher_value_cannot_smuggle_a_token_under_the_name
    kept = ChildEnv.renewer({ "AGENT_LEGACY_TOKEN" => "sk-live-pasted-token" }, {})
    refute kept.key?("AGENT_LEGACY_TOKEN")
  end

  def test_servers_and_lanes_still_drop_the_switch
    env = { "AGENT_LEGACY_TOKEN" => "off", "PATH" => "/bin" }
    refute ChildEnv.desk_server({}, env).key?("AGENT_LEGACY_TOKEN")
    refute ChildEnv.lane({}, env).key?("AGENT_LEGACY_TOKEN")
  end
end

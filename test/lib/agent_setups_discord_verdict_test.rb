# frozen_string_literal: true

# [unit] lib/agent_setups/discord_verdict.rb — Discord's answers about a bot
# token, mapped to ready or to a reason Alex McRitchie can act on. Plain Ruby:
# bin/agent-setup uses it on the Mac and AgentSetups::Command on the dyno.
#
#   ruby -Itest test/lib/agent_setups_discord_verdict_test.rb

require "minitest/autorun"
require_relative "../../lib/agent_setups/discord_verdict"

class AgentSetupsDiscordVerdictTest < Minitest::Test
  APP = "1560516264378507334"
  GUILD = "1332466565203103744"
  ME = { "id" => APP, "bot" => true, "username" => "Mason" }.freeze

  def verdict(**overrides)
    AgentSetups::DiscordVerdict.call(**{ me_status: 200, me: ME, expected_id: APP, expected_name: "Mason",
                                         guilds_status: 200, guilds: [ { "id" => GUILD } ], guild_id: GUILD }.merge(overrides))
  end

  def test_the_right_bot_in_the_server_is_ready
    result = verdict
    assert result.ok?
    assert_nil result.reason
    assert_equal APP, result.bot_user_id
  end

  def test_the_name_matches_ignoring_case_and_space
    assert verdict(expected_name: " mason ").ok?
  end

  def test_a_refused_token_names_the_fix
    result = verdict(me_status: 401, me: { "message" => "401: Unauthorized" })
    refute result.ok?
    assert_match(/Discord refused the token \(401\).*Reset it, paste it into the 1Password item/, result.reason)
    assert_match(/rate-limited/, verdict(me_status: 429, me: nil).reason)
    assert_match(/did not answer/, verdict(me_status: 0, me: nil).reason)
  end

  def test_a_user_token_is_not_a_bot
    assert_match(/not a bot's/, verdict(me: ME.merge("bot" => false)).reason)
  end

  def test_another_applications_token_is_named
    result = verdict(me: ME.merge("id" => "1405042649479647293"))
    refute result.ok?
    assert_equal "1405042649479647293", result.bot_user_id
    assert_match(/belongs to bot 1405042649479647293, not the application #{APP}/, result.reason)
  end

  # Regression (Carl, pending-agents-page): a blank expected id SKIPPED the id
  # check, so any bot's token verified on a card with no Application ID.
  def test_a_blank_expected_id_fails_and_never_passes_any_bot
    [ nil, "", "   " ].each do |blank|
      result = verdict(expected_id: blank)
      refute result.ok?, "expected_id #{blank.inspect} must fail, not skip the id check"
      assert_match(/no Application ID to check the token against/, result.reason)
      assert_equal APP, result.bot_user_id, "the bot's id is still reported for the card"
    end
  end

  def test_a_padded_expected_id_still_matches
    assert verdict(expected_id: " #{APP} ").ok?
  end

  def test_a_wrong_name_is_named
    assert_match(/named "Masonbot", not "Mason"/, verdict(me: ME.merge("username" => "Masonbot")).reason)
  end

  def test_a_bot_outside_the_server_is_sent_to_invite
    assert_match(/not in the server yet: use Invite/, verdict(guilds: [ { "id" => "1" } ]).reason)
    assert_match(/would not list the bot's servers \(HTTP 500\)/, verdict(guilds_status: 500, guilds: nil).reason)
  end

  def test_no_guild_means_no_membership_check
    assert verdict(guild_id: nil, guilds_status: nil, guilds: nil).ok?
  end
end

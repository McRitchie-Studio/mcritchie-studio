require "test_helper"
require_relative "../support/agent_message_fixtures"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [unit] The "typing…" pulse (AgentMessageTypingJob) and its guard
# (AgentMessage#typing_refusal): one POST /channels/{id}/typing as the bot the
# reply will use, only for a held, answered Discord message within the cap; a
# refused soul bot falls back to the shared bot silently; a Discord error is
# dropped, never raised into anything. Discord HTTP is stubbed.
class AgentMessageTypingJobTest < ActiveJob::TestCase
  include AgentMessageFixtures

  def claimed_message(soul: "avi")
    message = agent_message!(soul: soul)
    AgentMessage.claim!(soul: soul, worker: "w1")
    message.reload
  end

  def with_transport(transport)
    previous = AgentMessages::DiscordBot.transport
    AgentMessages::DiscordBot.transport = transport
    yield
  ensure
    AgentMessages::DiscordBot.transport = previous
  end

  # Records every call; answers by Authorization header from `answers`
  # (default 204, Discord's answer to a typing POST).
  def recorder(calls, answers = {})
    lambda do |method, url, headers, body|
      calls << { method: method, url: url, auth: headers["Authorization"], body: body }
      answers.fetch(headers["Authorization"], [ 204, "" ])
    end
  end

  def with_tokens(shared: "shared-token", soul: nil, soul_name: "avi", &block)
    with_env("DISCORD_AGENT_BOT_TOKEN", shared) do
      with_env(AgentMessages::DiscordBot.soul_token_env(soul_name), soul, &block)
    end
  end

  test "[unit] a pulse posts typing into the message's channel as the shared bot, with no body" do
    message = claimed_message
    calls = []
    with_tokens { with_transport(recorder(calls)) { AgentMessageTypingJob.perform_now(message.id, "w1") } }

    assert_equal 1, calls.size
    assert_equal :post, calls.first[:method]
    assert_equal "https://discord.com/api/v10/channels/#{DESK}/typing", calls.first[:url]
    assert_equal "Bot shared-token", calls.first[:auth]
    assert_nil calls.first[:body]
  end

  test "[unit] a soul with its own bot types as that bot, the one its reply uses" do
    message = claimed_message
    calls = []
    via = nil
    with_tokens(soul: "avi-token") do
      with_transport(recorder(calls)) { AgentMessageTypingJob.perform_now(message.id, "w1") }
      via = AgentMessages::BotSelector.choice("avi").via
    end

    assert_equal [ "Bot avi-token" ], calls.map { |c| c[:auth] }
    assert_equal AgentMessages::BotSelector::SOUL, via, "the reply would pick the same bot"
  end

  test "[unit] a refused soul bot falls back to shared typing once, and later pulses skip it" do
    message = claimed_message
    calls = []
    answers = { "Bot avi-token" => [ 403, '{"message":"Missing Permissions"}' ] }
    with_tokens(soul: "avi-token") do
      with_transport(recorder(calls, answers)) do
        AgentMessageTypingJob.perform_now(message.id, "w1")
        AgentMessageTypingJob.perform_now(message.id, "w1")
      end
    end

    assert_equal [ "Bot avi-token", "Bot shared-token", "Bot shared-token" ], calls.map { |c| c[:auth] }
    refused = message.events.where(kind: AgentMessageTypingJob::REFUSED_EVENT)
    assert_equal 1, refused.count
    assert_equal({ "token_env" => "DISCORD_BOT_TOKEN_AVI" }, refused.first.detail)
    refute_includes message.events.pluck(:kind), AgentMessageReplyJob::REFUSED_EVENT,
                    "a typing refusal does not change the reply's own bot choice"
    refute_match(/avi-token|shared-token/, message.events.to_json, "no token reaches the timeline")
  end

  test "[unit] a soul bot the reply job already found refused is not tried for typing" do
    message = claimed_message
    message.record!(AgentMessageReplyJob::REFUSED_EVENT, actor: "discord-bot", detail: {})
    calls = []
    with_tokens(soul: "avi-token") { with_transport(recorder(calls)) { AgentMessageTypingJob.perform_now(message.id, "w1") } }

    assert_equal [ "Bot shared-token" ], calls.map { |c| c[:auth] }
  end

  test "[unit] a refused shared bot, a 429, a 5xx or an unreachable Discord is dropped, never raised" do
    message = claimed_message
    [ [ 401, "{}" ], [ 429, '{"retry_after":1.5}' ], [ 502, "bad gateway" ] ].each do |answer|
      with_tokens { with_transport(->(*) { answer }) { AgentMessageTypingJob.perform_now(message.id, "w1") } }
    end
    unreachable = ->(*) { raise AgentMessages::DiscordBot::Error, "Discord unreachable: Net::ReadTimeout" }
    with_tokens { with_transport(unreachable) { AgentMessageTypingJob.perform_now(message.id, "w1") } }

    assert_enqueued_jobs 0, only: AgentMessageTypingJob
    assert_equal "claimed", message.reload.status
  end

  test "[unit] no bot token at all: no typing, silently" do
    message = claimed_message
    calls = []
    with_tokens(shared: nil) { with_transport(recorder(calls)) { AgentMessageTypingJob.perform_now(message.id, "w1") } }

    assert_empty calls
  end

  test "[unit] no pulse once the run is over: completed, released, or another worker's" do
    calls = []
    completed = claimed_message
    completed.complete!(worker: "w1", response_text: "Done.")
    released = claimed_message(soul: "ray")
    released.release!(worker: "w1", reason: "failed")

    with_tokens do
      with_transport(recorder(calls)) do
        AgentMessageTypingJob.perform_now(completed.id, "w1")
        AgentMessageTypingJob.perform_now(released.id, "w1")
        other = claimed_message
        AgentMessageTypingJob.perform_now(other.id, "someone-else")
        AgentMessageTypingJob.perform_now(-1, "w1")
      end
    end

    assert_empty calls
  end

  test "[unit] the guard: holder, Discord, answered sender, and the cap" do
    message = claimed_message
    claimed = message.claimed_at

    assert_nil message.typing_refusal(worker: "w1", now: claimed)
    assert_nil message.typing_refusal(worker: " w1 ", now: claimed + AgentMessage::TYPING_CAP)
    assert_equal "capped", message.typing_refusal(worker: "w1", now: claimed + AgentMessage::TYPING_CAP + 1)
    assert_equal "not_holder", message.typing_refusal(worker: "w2", now: claimed)
    assert_equal "not_holder", message.typing_refusal(worker: "", now: claimed)
    assert_equal AgentMailbox::Dispatcher::TYPING_CAP, AgentMessage::TYPING_CAP,
                 "the dispatcher stops asking where the board stops answering"
  end

  test "[unit] an audience that gets no answer never types, even if its row were somehow claimed" do
    owner_only = AgentMessages::Answerers.new(%w[owner])
    stranger = agent_message!(soul: "ray", status: "claimed", author_ref: "777000000000000009", claimed_by: "w1",
                              claimed_at: Time.current, lease_expires_at: 10.minutes.from_now, attempts: 1)
    refute_equal "owner", stranger.person.role

    assert_equal "not_answered", stranger.typing_refusal(worker: "w1", answerers: owner_only)

    stranger.update!(hold_released_at: Time.current, hold_released_by: "alex")
    assert_nil stranger.typing_refusal(worker: "w1", answerers: owner_only), "an admin-released hold is answered"

    held = agent_message!(soul: "ray", status: "held", author_ref: "777000000000000010")
    assert_equal "not_holder", held.typing_refusal(worker: "w1", answerers: owner_only)

    AgentMessages::Answerers.current = owner_only
    stranger.update!(hold_released_at: nil, hold_released_by: nil)
    calls = []
    with_tokens { with_transport(recorder(calls)) { AgentMessageTypingJob.perform_now(stranger.id, "w1") } }
    assert_empty calls
  end
end

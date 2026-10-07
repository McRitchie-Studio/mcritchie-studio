# frozen_string_literal: true

require "test_helper"
require "rake"

# [integration] `agent_sessions:grant_admin`, the operator's grant of an admin
# agent session from a shell on the hub (docs/agents/system/agent-sessions-design.md,
# section 3). bin/tiktok-draft presents the token it prints. Stdout carries the
# token and nothing else, so `export AGENT_ADMIN_SESSION_TOKEN="$(...)"` takes it
# without it ever being read; everything a person reads goes to stderr.
class AgentSessionsGrantAdminRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_sessions:grant_admin")
  end

  def grant(env = {})
    Rake::Task["agent_sessions:grant_admin"].reenable
    status = 0
    out, err = capture_io do
      with_env(env) { Rake::Task["agent_sessions:grant_admin"].invoke }
    rescue SystemExit => e
      status = e.status
    end
    [out, err, status]
  end

  def with_env(env)
    before = env.to_h { |k, _| [k, ENV[k]] }
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    before.each { |k, v| ENV[k] = v }
  end

  test "it grants an admin session and prints only its token on stdout" do
    out, err, status = grant("SOUL" => "xan")
    session = AgentSession.from_token(out.strip)

    assert_equal 0, status
    assert_equal 1, out.lines.size, "stdout is the token alone"
    assert_equal %w[xan admin operator_grant], [session.soul, session.tier, session.issued_by]
    assert_nil session.task_slug
    assert_in_delta 8.hours.from_now, session.expires_at, 5.seconds
    assert_match(/#{session.slug}.*xan.*admin/, err)
    refute_includes err, out.strip, "the token is never echoed where a person reads"
  end

  test "it defaults to Xan and takes Steffon" do
    assert_equal "xan", AgentSession.from_token(grant.first.strip).soul
    assert_equal "steffon", AgentSession.from_token(grant("SOUL" => "steffon").first.strip).soul
  end

  test "HOURS shortens the session and never lengthens it" do
    assert_in_delta 1.hour.from_now, AgentSession.from_token(grant("HOURS" => "1").first.strip).expires_at, 5.seconds

    %w[9 0 -1 soon].each do |hours|
      out, err, status = grant("HOURS" => hours)
      assert_equal ["", 1], [out, status], "HOURS=#{hours} is refused"
      assert_match(/HOURS/, err)
    end
  end

  test "a soul that may not hold the admin tier is refused and no session is made" do
    assert_no_difference -> { AgentSession.count } do
      out, err, status = grant("SOUL" => "carl")

      assert_equal ["", 1], [out, status]
      assert_match(/admin is held only by steffon and xan, not carl/, err)
    end
  end
end

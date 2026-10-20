require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] The CTO usage meter (AgentUsage, docs/agents/system/agent-usage.md):
# the rollup reads each answer's run summary, only client answers count
# against an app's allowance (public ones are metered apart), the gate warns at 80% and stops at 100%
# before a claim, owner and team are never capped, an admin's lift wins, and the
# upgrade rule names a price only from the tiers config. Allowances are stubbed;
# the shipped config caps only Vibe (25,000, the free tier).
class AgentUsageTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  NOW = Time.zone.parse("2026-10-16 12:00 MDT")

  setup do
    @app = apps(:turf_monster)
    @app.update!(package_tier: "builder", cto_cap_lifted_at: nil)
    @client = AgentPerson.create!(display_name: "Client", role: "client", client_domain: "turf_monster")
    @owner = AgentPerson.create!(display_name: "Owner", role: "owner")
  end

  def packages(builder: 1_000, pro: 5_000, team: nil)
    [ WorkspacePackage.new({ "key" => "vibe", "name" => "Vibe", "price_monthly" => 0, "cto_monthly_tokens" => 100 }),
      WorkspacePackage.new({ "key" => "builder", "name" => "Builder", "price_monthly" => 100, "cto_monthly_tokens" => builder }),
      WorkspacePackage.new({ "key" => "pro", "name" => "Pro", "price_monthly" => 500, "cto_monthly_tokens" => pro }),
      WorkspacePackage.new({ "key" => "team", "name" => "Team", "price_monthly" => 900, "cto_monthly_tokens" => team }) ]
  end

  def with_allowances(**kw, &block) = WorkspacePackage.stub(:all, packages(**kw), &block)

  # A completed Turf answer with these tokens, stamped as the board stamps it.
  def answered!(person:, tokens:, at: NOW - 1.day, cost: 0.01, duration: 2_000, soul: "turf_monster")
    message = agent_message!(soul: soul, person: person, status: "completed", completed_at: at)
    message.update_columns(run_meta: { "input_tokens" => tokens, "cache_read_tokens" => 0, "cache_creation_tokens" => 0,
                                       "output_tokens" => 0, "thinking_tokens" => 0, "total_cost_usd" => cost,
                                       "duration_ms" => duration, "model" => "m", "audience" => person.role })
    message
  end

  test "the shipped config caps only the free tier: Vibe at 25,000, every paid package blank" do
    allowances = WorkspacePackage.all.to_h { |p| [ p.key, p.cto_monthly_tokens ] }
    assert_equal 25_000, allowances.delete("vibe"), "Alex, 2026-10-19: the free budget is very small"
    assert allowances.values.all?(&:nil?), "paid tiers unchanged: #{allowances.inspect}"
    assert_equal 80, AgentUsage.warn_percent
    assert AgentUsage.meter(@app, now: NOW).unlimited?
  end

  test "totals sum every token kind, cost and duration, and skip a planted string" do
    a = answered!(person: @client, tokens: 100, cost: 0.02, duration: 1_000)
    answered!(person: @owner, tokens: 50, cost: 0.01, duration: 3_000)
    a.update_columns(run_meta: a.run_meta.merge("output_tokens" => "999999", "cache_read_tokens" => 7))
    totals = AgentUsage.totals(souls: %w[turf_monster], from: NOW - 3.days, to: NOW)

    assert_equal 2, totals.messages
    assert_equal 157, totals.tokens
    assert_in_delta 0.03, totals.cost_usd
    assert_equal 2_000, totals.avg_duration_ms
    assert_equal 107, AgentUsage.totals(souls: %w[turf_monster], from: NOW - 3.days, to: NOW, metered_only: true).tokens
  end

  test "daily rolls up per Denver day, oldest first, with empty days present" do
    answered!(person: @client, tokens: 10, at: Time.zone.parse("2026-10-15 23:30 MDT"))
    answered!(person: @client, tokens: 20, at: Time.zone.parse("2026-10-16 00:30 MDT"))
    days = AgentUsage.daily("turf_monster", days: 3, now: NOW)

    assert_equal [ Date.new(2026, 10, 14), Date.new(2026, 10, 15), Date.new(2026, 10, 16) ], days.map(&:first)
    assert_equal [ 0, 10, 20 ], days.map { |_, t| t.tokens }
  end

  test "the meter counts only client answers this month; the public is metered apart" do
    answered!(person: @client, tokens: 300)
    answered!(person: AgentPerson.create!(display_name: "Visitor", role: "public"), tokens: 7_000)
    answered!(person: @owner, tokens: 5_000)
    answered!(person: @client, tokens: 9_000, at: NOW - 30.days)
    with_allowances do
      meter = AgentUsage.meter(@app, now: NOW)
      assert_equal 300, meter.used, "public tokens never consume the allowance"
      assert_equal 7_000, meter.public_used
      assert_equal 1_000, meter.allowance
      assert_equal 30, meter.percent
      assert_equal :ok, meter.state
      assert_equal 3, meter.totals.messages
    end
  end

  test "the gate warns at 80%, stops at 100%, and never caps owner or team" do
    used = answered!(person: @client, tokens: 800)
    with_allowances do
      waiting = agent_message!(soul: "turf_monster", person: @client)
      assert_equal :warn, AgentUsage.gate(waiting, now: NOW).state
      used.update_columns(run_meta: used.run_meta.merge("input_tokens" => 1_000))
      assert_equal :stop, AgentUsage.gate(waiting, now: NOW).state

      owners = agent_message!(soul: "turf_monster", person: @owner)
      assert_equal :ok, AgentUsage.gate(owners, now: NOW).state
      team = AgentPerson.create!(display_name: "Team", role: "team")
      assert_equal :ok, AgentUsage.gate(agent_message!(soul: "turf_monster", person: team), now: NOW).state
    end
  end

  test "an admin's lift and a blank allowance are unlimited" do
    answered!(person: @client, tokens: 5_000)
    with_allowances do
      waiting = agent_message!(soul: "turf_monster", person: @client)
      assert_equal :stop, AgentUsage.gate(waiting, now: NOW).state
      @app.update!(cto_cap_lifted_at: NOW, cto_cap_lifted_by: "admin@x")
      assert_equal :ok, AgentUsage.gate(waiting, now: NOW).state
      assert AgentUsage.meter(@app, now: NOW).lifted
    end
    with_allowances(builder: nil) do
      @app.update!(cto_cap_lifted_at: nil)
      assert_equal :ok, AgentUsage.gate(agent_message!(soul: "turf_monster", person: @client), now: NOW).state
    end
  end

  test "suggestion: on track is none; projected over is the next tier up at its config price" do
    with_allowances do
      answered!(person: @client, tokens: 100)
      assert_nil AgentUsage.meter(@app, now: NOW).suggestion

      answered!(person: @client, tokens: 500)
      suggestion = AgentUsage.meter(@app, now: NOW).suggestion
      assert_equal :tier, suggestion.kind
      assert_equal "pro", suggestion.tier
      assert_equal 500, suggestion.price
      assert_equal :projected, suggestion.reason
      assert_equal "Pro ($500/month) raises it.", suggestion.line
    end
  end

  test "suggestion: capped twice this month suggests even when the trend is flat" do
    with_allowances do
      2.times do
        capped = agent_message!(soul: "turf_monster", person: @client)
        capped.record!("usage_capped", actor: "system")
        capped.events.last.update_columns(created_at: NOW - 1.hour)
      end
      assert_equal :capped_twice, AgentUsage.meter(@app, now: NOW).suggestion.reason
    end
  end

  test "suggestion: at the top, a configured top-up, else talk to us; never an invented price" do
    @app.update!(package_tier: "pro")
    answered!(person: @client, tokens: 4_900)
    with_allowances(team: 5_000) do
      meter = AgentUsage.meter(@app, now: NOW)
      none = AgentUsage::Suggestion.for(meter, packages: packages(team: 5_000), topup: { "tokens" => nil, "price" => nil })
      assert_equal :talk, none.kind
      assert_nil none.price
      topup = AgentUsage::Suggestion.for(meter, packages: packages(team: 5_000), topup: { "tokens" => 1_000_000, "price" => 25 })
      assert_equal :topup, topup.kind
      assert_equal "A top-up of 1,000,000 tokens is $25.", topup.line
    end
  end

  test "the usage ask: code-formatted totals, today, and the allowance; team and above only" do
    answered!(person: @client, tokens: 600, at: NOW - 2.hours, cost: 0.5, duration: 4_000)
    answered!(person: @owner, tokens: 400, at: NOW - 3.days, cost: 0.25, duration: 2_000)
    with_allowances do
      text = AgentProposals::Queries.run("usage", {}, app: "turf-monster", now: NOW)
      assert_equal "Turf Monster agent usage, October so far: 2 answers, 1,000 tokens (in 1,000 · cache read 0 · " \
                   "cache write 0 · out 0), $0.75, avg 3.0s. Today: 1 answer, 600 tokens (in 600 · cache read 0 · " \
                   "cache write 0 · out 0), $0.50, avg 4.0s. Allowance: 60% of 1,000 tokens used (Builder). " \
                   "Pro ($500/month) raises it.", text
    end
    registry = AgentProposal.registry
    client = AgentMailbox::Audience.new(role: "client", client_domain: "turf_monster")
    team = AgentMailbox::Audience.new(role: "team")
    refute_includes registry.catalog("turf_monster", audience: client).map { |c| c["capability"] }, "usage"
    assert_includes registry.catalog("turf_monster", audience: team).map { |c| c["capability"] }, "usage"
    assert_includes registry.catalog("avi", audience: team).map { |c| c["capability"] }, "usage"
  end

  test "suggestion: a tier with no price (Enterprise) is named without one" do
    enterprise = WorkspacePackage.new({ "key" => "enterprise", "name" => "Enterprise", "price_label" => "Custom" })
    @app.update!(package_tier: "team")
    answered!(person: @client, tokens: 900)
    ladder = packages(team: 1_000) + [ enterprise ]
    WorkspacePackage.stub(:all, ladder) do
      suggestion = AgentUsage.meter(@app, now: NOW).suggestion
      assert_equal "enterprise", suggestion.tier
      assert_nil suggestion.price
      assert_equal "Enterprise raises it.", suggestion.line
    end
  end

  test "the cap reply and the warn line are code, with the suggestion's price" do
    answered!(person: @client, tokens: 1_000)
    with_allowances do
      meter = AgentUsage.meter(@app, now: NOW)
      reply = AgentUsage.cap_reply(meter)
      assert_match(/used its monthly agent allowance.*resets Nov 1\. Pro \(\$500\/month\) raises it\. \[Upgrade your plan\]\(http:\/\/www\.example\.com\/packages\) or contact us\.\z/, reply)
      refute_match(/owner can raise/, reply)
    end
    with_allowances(builder: 1_200) do
      assert_match(/\A_83% of this app's monthly agent allowance is used\./, AgentUsage.warn_line(AgentUsage.meter(@app, now: NOW)))
    end
  end

  test "an unlimited meter skips the capped-count query; a metered one reads it" do
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("agent_message_events") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { AgentUsage.meter(@app, now: NOW) }
    assert_empty queries, "the shipped config has no allowance, so nothing reads the events"

    with_allowances do
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { AgentUsage.meter(@app, now: NOW) }
    end
    assert_equal 1, queries.size, "control: with an allowance the capped count is read"
  end

  test "a claim reads each app's meter once, however many capped candidates it skips" do
    answered!(person: @client, tokens: 1_000)
    3.times { agent_message!(soul: "turf_monster", person: @client) }
    calls = 0
    real = AgentUsage.method(:meter)
    with_allowances do
      AgentUsage.stub(:meter, ->(*args, **kw) { calls += 1; real.call(*args, **kw) }) do
        AgentMessage.claim!(soul: "turf_monster", worker: "w1", now: NOW)
      end
    end
    assert_equal 3, AgentMessage.where(action_summary: "usage cap").count
    assert_equal 1, calls
  end

  test "an owner's totals and meter drop the dollar figure; an admin's keep it" do
    answered!(person: @client, tokens: 100, cost: 0.25)
    totals = AgentUsage.totals(souls: %w[turf_monster], from: NOW - 3.days, to: NOW)
    assert_match(/\$0\.25/, AgentUsage.totals_line(totals))
    refute_match(/\$/, AgentUsage.totals_line(totals.without_cost))
    refute AgentUsage.meter(@app, now: NOW).without_cost.as_json["month"].key?("cost_usd")
    assert_in_delta 0.25, AgentUsage.meter(@app, now: NOW).as_json.dig("month", "cost_usd")
  end
end

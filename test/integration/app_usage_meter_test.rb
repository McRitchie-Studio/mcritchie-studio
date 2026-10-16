require "test_helper"

# [integration] The CTO usage meter on the owner pages (AgentUsage,
# docs/agents/system/agent-usage.md): the app page and the CTO's settings page
# show this month's meter to the owner and an admin; the JSON endpoint answers
# them alone; strangers and visitors get the same 404 / sign-in as the pages;
# only an admin sets the tier and lifts the cap, and a lift makes the meter
# unlimited. [component] The meter renders used, allowance, percent and the
# config-priced suggestion.
class AppUsageMeterTest < ActionDispatch::IntegrationTest
  setup do
    @app = apps(:turf_monster)
    @app.update!(package_tier: "builder")
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist")
    @owner = User.create!(email: "alex@turfmonster.media", name: "Turf Owner", role: "viewer")
    @stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
    AppMembership.create!(app: @app, user: @owner)
    client = AgentPerson.create!(display_name: "Client", role: "client", client_domain: "turf_monster")
    row = AgentMessage.create!(channel: "discord", external_id: "usage-page-1", channel_ref: "c", thread_key: "t",
                               soul_slug: "turf_monster", status: "completed", completed_at: 1.minute.ago, content: "x",
                               person: client)
    row.update_columns(run_meta: { "input_tokens" => 850, "output_tokens" => 0, "total_cost_usd" => 0.42,
                                   "duration_ms" => 3_000, "audience" => "client" })
    @packages = [ WorkspacePackage.new({ "key" => "builder", "name" => "Builder", "price_monthly" => 100, "cto_monthly_tokens" => 1_000 }),
                  WorkspacePackage.new({ "key" => "pro", "name" => "Pro", "price_monthly" => 500, "cto_monthly_tokens" => 5_000 }) ]
  end

  test "[integration] the owner sees the meter on the app page and the CTO page, and reads it as JSON" do
    log_in_as(@owner)
    WorkspacePackage.stub(:all, @packages) do
      get application_path("turf-monster")
      assert_response :success
      assert_select "[data-test='usage-meter'][data-state='warn']"
      assert_select "[data-test='usage-meter-line']", text: /850\s+of 1,000 tokens/
      assert_select "[data-test='usage-meter-percent']", text: "85%"
      assert_select "[role='progressbar'][aria-valuenow='85']"
      assert_select "[data-test='usage-suggestion'][data-kind='tier']", text: "Pro ($500/month) raises it."
      assert_select "[data-test='application-usage-month']", text: /1 answer, 850 tokens .*\$0\.42, avg 3\.0s\./
      assert_select "[data-test='application-usage-admin']", count: 0

      get settings_agent_path("turf-monster")
      assert_select "[data-test='agent-usage-card'] [data-test='usage-meter'][data-state='warn']"

      get usage_application_path("turf-monster", format: :json)
      assert_response :success
      data = response.parsed_body["data"]
      assert_equal [ 850, 1_000, 85, "warn", "pro", 500 ],
                   [ data["used"], data["allowance"], data["percent"], data["state"], data.dig("suggestion", "tier"), data.dig("suggestion", "price") ]
      assert_equal 1, data.dig("today", "messages")
    end
  end

  test "[integration] with the shipped config the meter is unlimited, no bar, no suggestion" do
    log_in_as(@owner)
    get application_path("turf-monster")
    assert_select "[data-test='usage-meter'][data-state='unlimited']"
    assert_select "[role='progressbar']", count: 0
    assert_select "[data-test='usage-suggestion']", count: 0
  end

  test "[integration] strangers and visitors never see usage; an owner cannot touch the cap" do
    get usage_application_path("turf-monster", format: :json)
    assert_response :unauthorized

    log_in_as(@stranger)
    get usage_application_path("turf-monster", format: :json)
    assert_response :not_found

    log_in_as(@owner)
    patch usage_cap_application_path("turf-monster"), params: { usage_cap: { package_tier: "", lifted: "1" } }
    assert_response :redirect
    refute_equal application_url("turf-monster"), response.location, "the admin wall turns an owner's write away"
    assert_nil @app.reload.cto_cap_lifted_at
    assert_equal "builder", @app.package_tier
  end

  test "[integration] an admin sets the tier and lifts the cap; the meter goes unlimited, then back" do
    log_in_as(users(:alex))
    WorkspacePackage.stub(:all, @packages) do
      get application_path("turf-monster")
      assert_select "[data-test='application-usage-admin']"

      patch usage_cap_application_path("turf-monster"), params: { usage_cap: { package_tier: "builder", lifted: "1" } }
      assert_redirected_to application_path("turf-monster")
      assert @app.reload.cto_cap_lifted_at
      assert_equal users(:alex).email, @app.cto_cap_lifted_by
      get application_path("turf-monster")
      assert_select "[data-test='usage-meter'][data-state='unlimited']", text: /cap lifted by an admin/

      patch usage_cap_application_path("turf-monster"), params: { usage_cap: { package_tier: "pro", lifted: "0" } }
      assert_nil @app.reload.cto_cap_lifted_at
      assert_equal "pro", @app.package_tier

      patch usage_cap_application_path("turf-monster"), params: { usage_cap: { package_tier: "platinum", lifted: "0" } }
      assert_equal "pro", @app.reload.package_tier, "an unknown tier is refused"
    end
  end
end

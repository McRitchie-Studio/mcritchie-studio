require "test_helper"
require_relative "../support/report_destination_fixtures"

# [integration] App owners (docs/agents/system/app-owners.md): an owner signs in,
# sees their app in the sidebar, opens the app and, from it, the CTO's settings,
# and sets the daily report's channel, writing the same ReportDestination row as
# /admin/report_destinations. Anyone else gets 404, never 403; a visitor is sent
# to sign in. Server-side, every action.
class AppOwnersFlowTest < ActionDispatch::IntegrationTest
  include ReportDestinationFixtures

  setup do
    @cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse", emoji: "🐉", color: "#DC2626", position: 5)
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist")
    Agent.create!(slug: "tyrion", name: "Tyrion", status: "active", agent_type: "specialist")
    @owner = User.create!(email: "alex@turfmonster.media", name: "Turf Owner", role: "viewer")
    @cyvasse_owner = User.create!(email: "cyvasse-owner@example.com", name: "Cyvasse Owner", role: "viewer")
    @stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @owner)
    AppMembership.create!(app: @cyvasse, user: @cyvasse_owner)
  end

  def sidebar = css_select("#studio-link-sidebar")

  # The release's post_deploy_cmd, end to end: the catalog writes the rows, the seed the
  # memberships. The hub owner is an admin (User's seats restore the role at sign-in), so
  # the page opens on the row alone, and the sidebar is what the memberships change.
  test "[integration] after the release's seed, the hub owner opens Voicebox and the sidebar counts every app" do
    log_in_as(User.find_by!(email: "alex@mcritchie.studio"))
    get application_path("voicebox")
    assert_response :not_found, "control: before the seed there is no such app"
    get links_path
    assert_select "#studio-link-sidebar a[href=?]", applications_path, count: 0

    capture_io { load Rails.root.join("db/seeds/00_apps.rb") }
    assert_empty AppMembership.seed_failures(AppMembership.seed_owners!)

    get application_path("voicebox")
    assert_response :success
    assert_select "h1, h2", text: /Voicebox/
    get links_path
    assert_select "#studio-link-sidebar a[href=?]", application_path("mcritchie-studio")
    assert_select "#studio-link-sidebar a[href=?]", application_path("alex-build")
    assert_select "#studio-link-sidebar a[href=?]", application_path("voicebox"), count: 0
    assert_select "#studio-link-sidebar a[href=?]", applications_path, text: /All \d+ Apps/
  end

  def turf_channels
    shared = channel!(external_id: REPORTS, name: "reports")
    turf = DiscordChannel.create!(guild_external_id: GUILD, external_id: NEWS, name: "turf-reports", kind: "text",
                                  postable: true, postable_souls: [ "turf_monster" ], category_name: "Turf", synced_at: Time.current)
    [ shared, turf ]
  end

  test "[integration] the owner's sidebar names up to two apps, then All apps; the app page links the CTO; a non-owner's has neither" do
    log_in_as(@owner)
    get settings_agent_path("turf-monster")
    assert_response :success
    assert_select "#studio-link-sidebar a[href=?]", application_path("turf-monster"), text: /Turf Monster/
    assert_select "#studio-link-sidebar a[href=?]", settings_agent_path("turf-monster"), count: 0
    assert_select "#studio-link-sidebar a[href=?]", applications_path, count: 0

    get application_path("turf-monster")
    assert_select "main a[href=?]", settings_agent_path("turf-monster"), text: /Settings/
    assert_select "main a[href=?]", pipeline_application_path("turf-monster")

    AppMembership.create!(app: @cyvasse, user: @owner)
    get applications_path
    assert_select "#studio-link-sidebar a[href=?]", application_path("cyvasse"), text: /Cyvasse/
    assert_select "#studio-link-sidebar a[href=?]", applications_path, count: 0

    AppMembership.create!(app: apps(:mcritchie_studio), user: @owner)
    get applications_path
    assert_select "#studio-link-sidebar a[href=?]", applications_path, text: /All \d+ Apps/
    assert_select "#studio-link-sidebar a[href^='/applications/']", count: 2

    log_in_as(@stranger)
    get root_path
    assert_select "#studio-link-sidebar", 1, "the sidebar renders for the stranger, so the absence below is real"
    assert_select "#studio-link-sidebar a[href^='/applications']", count: 0
    assert_select "#studio-link-sidebar a[href$='/settings']", count: 0
  end

  test "[integration] a client CTO's row draws its avatar; an unusable portrait costs the emoji, never the page" do
    AppMembership.create!(app: App.create!(slug: "pawsome", name: "Pawsome", emoji: "🐾", color: "#DC2626"), user: @stranger)
    row = AppCto.new(app_slug: "pawsome", name: "Rex").tap { |cto| cto.save!(validate: false) }
    log_in_as(@stranger)
    icon = "#studio-link-sidebar a[href='/applications/pawsome'] .studio-emoji-swap-base"

    { BuildIntake::Animals.all.first => "#{icon} svg.cto-animal", "harbor" => "#{icon} img[src*='cto_portraits/harbor']" }.each do |portrait, drawn|
      row.update_column(:portrait, portrait)
      get root_path
      assert_select drawn, 1, portrait
    end
    row.update_column(:portrait, "retired")
    get root_path
    assert_select icon, text: "🐾"
  end

  test "[integration] an owner sees only their app: list, page, health frame and CTO card" do
    log_in_as(@owner)

    get applications_path
    assert_response :success
    assert_select "[data-test='application-row']", count: 1
    assert_select "[data-test='application-row'][data-app='turf-monster']"

    get application_path("turf-monster")
    assert_response :success
    assert_select "h1", text: /\A\W*Turf Monster\z/
    assert_select "turbo-frame#application-health[src=?]", health_application_path("turf-monster")
    assert_select "[data-test='application-cto-name']", text: "Turf"
    assert_select "a[href=?]", settings_agent_path("turf-monster")
    assert_select "[data-test='application-owners']", count: 0

    with_env("HEALTH_TOKEN_TURF_MONSTER", nil) do
      get health_application_path("turf-monster")
    end
    assert_response :success
    assert_select "[data-test='application-health'][data-state='not_wired']"
  end

  test "[integration] anyone but the owner or an admin gets 404 on every page and the write; a visitor signs in" do
    paths = [ [ :get, application_path("turf-monster") ], [ :get, health_application_path("turf-monster") ],
              [ :get, settings_agent_path("turf-monster") ], [ :patch, settings_agent_path("turf-monster") ] ]

    paths.each do |verb, path|
      send(verb, path)
      assert_redirected_to login_path, "#{verb} #{path} as a visitor"
    end

    log_in_as(@cyvasse_owner)
    paths.each do |verb, path|
      send(verb, path, params: { report_destination: { discord_channel_id: "", enabled: "1" } })
      assert_response :not_found, "#{verb} #{path} as another app's owner"
    end
    get settings_agent_path("tyrion")
    assert_response :success, "their own CTO is theirs"

    log_in_as(@stranger)
    [ applications_path, settings_agents_path, application_path("cyvasse"), application_path("no-such-app"),
      settings_agent_path("alex"), settings_agent_path("tyrion") ].each do |path|
      get path
      assert_response :not_found, "GET #{path} as a stranger"
    end
    assert_nil ReportDestination.find_by(report_key: "cto_report:turf_monster"), "no write got through"
  end

  test "[integration] an admin sees every app with its owners, and every CTO" do
    log_in_as(users(:alex))
    get applications_path
    assert_response :success
    assert_select "[data-test='application-row']", count: App.count

    get application_path("cyvasse")
    assert_response :success
    assert_select "[data-test='application-owners']", text: /cyvasse-owner@example.com/

    get settings_agents_path
    assert_select "[data-test='agent-settings-row']", count: 3
  end

  test "[integration] the owner picks a channel Turf's own bot can post in; it lands on the admin page's row" do
    shared, turf = turf_channels
    log_in_as(@owner)

    with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", "turf-soul-secret") do
      get settings_agent_path("turf-monster")
      assert_response :success
      assert_select "[data-test='agent-report-bot'][data-via='soul_bot']"
      assert_select "[data-test='agent-report-channel'] option[value='#{turf.id}']"
      assert_select "[data-test='agent-report-channel'] option[value='#{shared.id}']", count: 0
      assert_not_includes response.body, "turf-soul-secret"
      assert_not_includes response.body, "DISCORD_BOT_TOKEN"

      patch settings_agent_path("turf-monster"), params: { report_destination: { discord_channel_id: shared.id, enabled: "1" } }
      assert_redirected_to settings_agent_path("turf-monster")
      assert_nil ReportDestination.find_by(report_key: "cto_report:turf_monster"), "a channel the picker does not offer is refused"

      patch settings_agent_path("turf-monster"), params: { report_destination: { discord_channel_id: turf.id, enabled: "1" } }
      follow_redirect!
      assert_match "Daily report: #turf-reports, on.", response.body
      assert_select "[data-test='agent-report-setting'][data-state='on']"
    end

    destination = ReportDestination.find_by!(report_key: "cto_report:turf_monster")
    assert_equal [ turf, true, @owner.email ], [ destination.discord_channel, destination.enabled?, destination.updated_by ]

    log_in_as(users(:alex))
    get admin_report_destinations_path
    assert_select "[data-report-key='cto_report:turf_monster'][data-state='on']"
  end

  test "[integration] without Turf's own token the shared bot's channels are offered; turning it off keeps the channel" do
    shared, = turf_channels
    log_in_as(@owner)

    with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", nil) do
      get settings_agent_path("turf-monster")
      assert_select "[data-test='agent-report-bot'][data-via='shared_bot']"
      assert_select "[data-test='agent-report-channel'] option[value='#{shared.id}']"

      patch settings_agent_path("turf-monster"), params: { report_destination: { discord_channel_id: shared.id, enabled: "1" } }
      patch settings_agent_path("turf-monster"), params: { report_destination: { discord_channel_id: shared.id, enabled: "0" } }
    end

    destination = ReportDestination.find_by!(report_key: "cto_report:turf_monster")
    assert_equal [ shared, false ], [ destination.discord_channel, destination.enabled? ]
    assert_nil ReportDestination.find_by(report_key: "cto_report:cyvasse"), "nothing reaches another app's row"
  end
end

require "test_helper"

# [unit] AppOwnership: who may see which app and CTO, the CTO map read from
# config/cto_reports.yml, the owner's sidebar rule (singular / plural / none),
# and the report channels a CTO's picker offers (docs/agents/system/app-owners.md).
class AppOwnershipTest < ActiveSupport::TestCase
  setup do
    @cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse", emoji: "🐉", color: "#DC2626", position: 5)
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist", metadata: { "emoji" => "🐲" })
    Agent.create!(slug: "tyrion", name: "Tyrion", status: "active", agent_type: "specialist")
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    @stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
  end

  def own!(user, app) = AppMembership.create!(app: app, user: user)

  test "[unit] the CTO map comes from cto_reports.yml, named by the domain's reply_name, else the agent, else the soul" do
    ctos = AppOwnership.ctos.index_by(&:domain)

    turf = ctos.fetch("turf_monster")
    assert_equal [ "turf-monster", "turf_monster", "turf-monster", "Turf", "cto_report:turf_monster" ],
                 [ turf.app_slug, turf.soul, turf.slug, turf.display_name, turf.report_key ]
    assert_equal "Tyrion", ctos.fetch("cyvasse").display_name, "no reply_name for cyvasse: the Agent row's name"
    assert_equal "Avi", ctos.fetch("mcritchie_studio").display_name
    assert_nil ctos.fetch("mcritchie_studio").agent, "no avi Agent row here: the soul still maps"
    assert_equal "avi", ctos.fetch("mcritchie_studio").slug
    assert_equal "turf_monster", AppOwnership.cto_for_agent("turf-monster").domain
    assert_nil AppOwnership.cto_for_agent("alex"), "a soul that is no app's CTO has no settings page"
  end

  test "[unit] an owner manages only their own app; an admin manages every app; nobody else any" do
    own!(@owner, apps(:turf_monster))

    assert AppOwnership.manage_app?(@owner, "turf-monster")
    assert_not AppOwnership.manage_app?(@owner, "cyvasse")
    assert_not AppOwnership.manage_app?(@stranger, "turf-monster")
    assert_not AppOwnership.manage_app?(nil, "turf-monster")
    assert AppOwnership.manage_app?(users(:alex), "cyvasse")

    assert_equal [ "turf-monster" ], AppOwnership.visible_apps(@owner).pluck(:slug)
    assert_empty AppOwnership.visible_apps(@stranger)
    assert_equal App.count, AppOwnership.visible_apps(users(:alex)).count
    assert_equal [ "turf_monster" ], AppOwnership.visible_ctos(@owner).map(&:domain)
    assert_equal 3, AppOwnership.visible_ctos(users(:alex)).size
  end

  test "[unit] sidebar: one app (and its pipeline) and one CTO by name, two of each as Applications and Agents, none for a non-owner" do
    assert_empty AppOwnership.sidebar_links(@stranger)
    assert_empty AppOwnership.sidebar_links(users(:alex)), "an admin who owns nothing gets no owner links"

    own!(@owner, apps(:turf_monster))
    single = AppOwnership.sidebar_links(@owner)
    assert_equal [ [ "Turf Monster", "/applications/turf-monster" ], [ "Pipeline", "/applications/turf-monster/pipeline" ],
                   [ "Turf", "/agents/turf-monster/settings" ] ],
                 single.map { |l| [ l.label, l.href ] }
    assert_equal "🐲", single.last.emoji

    own!(@owner, @cyvasse)
    plural = AppOwnership.sidebar_links(@owner)
    assert_equal [ [ "Applications", "/applications" ], [ "Agents", "/agents/settings" ] ], plural.map { |l| [ l.label, l.href ] }
  end

  test "[unit] an admin's own memberships decide its labels" do
    alex = users(:alex)
    alex.save! # fixtures skip callbacks, so give the row its slug
    own!(alex, apps(:mcritchie_studio))

    assert_equal [ "McRitchie Studio", "Pipeline", "Avi" ], AppOwnership.sidebar_links(mason).map(&:label)
  end

  test "[unit] report channels: the CTO's own bot's postable set when its token is set, else the shared bot's" do
    guild = "940000000000000001"
    both = DiscordChannel.create!(guild_external_id: guild, external_id: "1", name: "both", kind: "text", postable: true, postable_souls: [ "turf_monster" ])
    shared_only = DiscordChannel.create!(guild_external_id: guild, external_id: "2", name: "shared-only", kind: "text", postable: true)
    DiscordChannel.create!(guild_external_id: guild, external_id: "3", name: "gone", kind: "text", postable: true,
                           postable_souls: [ "turf_monster" ], archived_at: 1.hour.ago)
    turf = AppOwnership.cto_for_app("turf-monster")

    with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", nil) do
      assert_equal [ both, shared_only ].sort_by(&:id), AppOwnership.report_channels(turf).sort_by(&:id)
    end
    with_env("DISCORD_BOT_TOKEN_TURF_MONSTER", "turf-secret") do
      assert AppOwnership.report_bot(turf).soul_bot?
      assert_equal [ both ], AppOwnership.report_channels(turf).to_a
    end
  end
end

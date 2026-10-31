require "test_helper"
require_relative "../../support/agent_message_fixtures"

# A shipped release told on Slack (ReleaseNotes::SlackAnnouncement), against the
# real config/agent_media.yml and config/agent_routes.yml, with a stubbed Slack
# transport: one #agents-general summary as Mason, one post per shipped app in its
# channel as that app's soul, the smoke verdict in the post's thread, exactly once,
# and never an exception into the ship.
class ReleaseNotesSlackAnnouncementTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  GENERAL = "C0CD8ETBZBM".freeze
  TURF = "C0CDPEKDABB".freeze
  CYVASSE = "C0CDG8ZQYTX".freeze
  HUB = "C0CD66BGSSK".freeze
  OWNER = "U0CCSMUMQJV".freeze

  class FakeTransport
    attr_reader :calls

    def initialize(fail_channel: nil, error: nil)
      @calls = []
      @seq = 0
      @fail_channel = fail_channel
      @error = error
    end

    def call(_method, params, _token)
      @calls << params
      raise @error if @fail_channel && params[:channel] == @fail_channel && params[:thread_ts].nil?

      @seq += 1
      [ 200, {}, { ok: true, channel: params[:channel], ts: "1762000000.#{format('%06d', @seq)}" }.to_json ]
    end

    def to(channel) = calls.select { |c| c[:channel] == channel }
  end

  setup do
    Media::Config.reset!
    AgentMessages::SlackRoutes.reset!
  end

  def task!(title, repos, pr: nil)
    devops = { "shape" => "backend", "repositories" => repos }
    devops["pr_url"] = pr if pr
    Task.create!(title: title, stage: "shipped", metadata: { "devops" => devops })
  end

  def shipped_release!
    release = Release.create!(slug: "rel-20261030-slack1", branch: "release", state: "shipped", deployed_sha: "aaaa111222333",
                              metadata: { "deployed_apps" => { "turf-monster" => { "sha" => "bbbb222333444" },
                                                               "cyvasse" => { "sha" => "cccc333444555" } } })
    @turf = task!("Turf Live Board Polish", [ "turf-monster" ],
                  pr: "https://github.com/McRitchie-Studio/turf-monster/pull/812")
    @cyv = task!("Cyvasse Lobby Chat Fix", [ "cyvasse" ])
    @hub = task!("Hub Slack Release Posts", [ "mcritchie-studio" ],
                 pr: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/2350")
    [ @turf, @cyv, @hub ].each { |t| t.update_columns(release_slug: release.slug) }
    release
  end

  def green(repo, sha)
    { "checks" => [ { "path" => "/up", "url" => "https://#{repo}.example/up", "code" => "200", "ok" => true },
                    { "path" => "/", "url" => "https://#{repo}.example/", "code" => "200", "ok" => true } ],
      "sha" => { "sha" => sha, "ok" => true, "reason" => "" } }
  end

  def smoke_all_green
    { "turf-monster" => green("turf", "bbbb222333444"), "cyvasse" => green("cyvasse", "cccc333444555"),
      "mcritchie-studio" => green("hub", "aaaa111222333") }
  end

  def announce(release, transport, smoke: smoke_all_green, dry_run: false)
    slack = Media::Slack.new(client: Media::Slack::Client.new(token: "xoxb-test", transport: transport))
    ReleaseNotes::SlackAnnouncement.new(release: release, smoke: smoke, slack: slack).call(dry_run: dry_run)
  end

  # --- builders ----------------------------------------------------------------

  test "[unit] the general summary: release, each app with its emoji and prod SHA, each card with task and PR links" do
    text = ReleaseNotes::SlackAnnouncement.new(release: shipped_release!).general_text

    assert_includes text, "*rel-20261030-slack1* shipped to production"
    assert_includes text, "🐊 *Turf Monster* `bbbb222`"
    assert_includes text, "🐉 *Cyvasse* `cccc333`"
    assert_includes text, "*McRitchie Studio* `aaaa111`"
    assert_includes text, "<https://mcritchie.studio/tasks/#{@turf.slug}|#{@turf.slug}> · " \
                          "<https://github.com/McRitchie-Studio/turf-monster/pull/812|PR #812>"
    assert_includes text, "<https://mcritchie.studio/tasks/#{@cyv.slug}|#{@cyv.slug}>"
    assert_operator text.lines.size, :<=, 8, "compact: one line per app and per card"
  end

  test "[unit] an app's post names its cards one line each and that a smoke test follows" do
    announcement = ReleaseNotes::SlackAnnouncement.new(release: shipped_release!)
    turf = announcement.app_groups.find { |g| g[:repo] == "turf-monster" }
    text = announcement.app_text(turf)

    assert_equal 3, text.lines.size
    assert_includes text, "<https://mcritchie.studio/tasks/#{@turf.slug}|Turf Live Board Polish>"
    assert_includes text, "Running a production smoke test"
  end

  test "[unit] green smoke is one line; red names the failure with evidence and mentions Alex McRitchie" do
    announcement = ReleaseNotes::SlackAnnouncement.new(release: shipped_release!, smoke: {
      "turf-monster" => green("turf", "bbbb222333444"),
      "cyvasse" => { "checks" => [ { "path" => "/up", "url" => "https://cyvasse.example/up", "code" => "503", "ok" => false },
                                   { "path" => "/", "url" => "https://cyvasse.example/", "code" => "200", "ok" => true } ],
                     "sha" => { "sha" => "cccc333444555", "ok" => false, "reason" => "heroku runs dddd999" } }
    })
    turf, cyv, hub = %w[turf-monster cyvasse mcritchie-studio].map { |r| announcement.app_groups.find { |g| g[:repo] == r } }

    green_line = announcement.smoke_text(turf)
    assert_equal ":white_check_mark: smoke green: /up 200, home 200, 2 pages checked · runs `bbbb222`", green_line
    assert_equal 1, green_line.lines.size

    red = announcement.smoke_text(cyv)
    assert_includes red, "smoke red <@#{OWNER}>"
    assert_includes red, "/up → 503 (https://cyvasse.example/up)"
    assert_includes red, "not proven at `cccc333`: heroku runs dddd999"

    assert_includes announcement.smoke_text(hub), "no smoke result reached the hub", "no result is red, never green"
  end

  test "[unit] the hub's post-ship seal rides its smoke: a red seal turns a green smoke red" do
    release = shipped_release!
    release.record_smoke_seal!(Release::SmokeSeal.from_result(passed: false, summary: "2 of 9 checks failed"))
    announcement = ReleaseNotes::SlackAnnouncement.new(release: release, smoke: smoke_all_green)
    hub = announcement.app_groups.find { |g| g[:repo] == "mcritchie-studio" }

    assert_includes announcement.smoke_text(hub), "post-ship seal red: 2 of 9 checks failed"
  end

  test "[unit] who speaks where: the channel's own soul (turf_monster, tywin), else Steffon; Mason in general" do
    announcement = ReleaseNotes::SlackAnnouncement.new(release: shipped_release!)

    assert_equal "turf_monster", announcement.app_soul(TURF)
    assert_equal "tywin", announcement.app_soul(CYVASSE)
    assert_equal "steffon", announcement.app_soul(HUB)
    assert_equal "mason", announcement.general_soul
    assert_equal GENERAL, announcement.general_home.channel_id
  end

  # --- posting ----------------------------------------------------------------

  test "[integration] one general post, one post per app as its soul, and the smoke verdict in that thread" do
    transport = FakeTransport.new
    result = announce(shipped_release!, transport)

    assert_equal 1, transport.to(GENERAL).size
    assert_equal "Mason", transport.to(GENERAL).sole[:username]
    { TURF => "Turf", CYVASSE => "Tywin", HUB => "Steffon" }.each do |channel, name|
      app_post, smoke = transport.to(channel)
      assert_nil app_post[:thread_ts]
      assert_equal name, app_post[:username]
      assert_equal name, smoke[:username]
      assert_match(/\A:white_check_mark: smoke green/, smoke[:text])
      assert smoke[:thread_ts].present?
      assert_equal 2, transport.to(channel).size
    end
    assert_equal "Slack posts: 7 sent / 0 failed", result.line
    assert_equal 7, SlackPost.where(release_slug: "rel-20261030-slack1", status: "posted", kind: "release").count
  end

  test "[integration] each app post is held as its thread, so Alex McRitchie's reply there routes to that soul" do
    transport = FakeTransport.new
    announce(shipped_release!, transport)
    turf_post = transport.to(TURF).first
    ts = SlackPost.find_by(channel_id: TURF, thread_ts: nil, kind: "release").ts

    row = AgentMessage.find_by!(channel: "slack", external_id: "#{TURF}:#{ts}")
    assert_equal [ "completed", "turf_monster", "release", "slack:#{TURF}:#{ts}" ],
                 [ row.status, row.soul_slug, row.routed_by, row.thread_key ]
    assert_equal turf_post[:text], row.response_text
    assert_nil row.person_id

    ingest = AgentMessages::SlackIngest.new
    result = ingest.send(:route, { "channel" => TURF, "ts" => "1762000099.000001",
                                   "thread_ts" => ts, "user" => OWNER, "text" => "what changed on the live board?" })
    assert_equal [ "turf_monster", "thread" ], [ result.soul, result.routed_by ]

    # #mcritchie-studio has no default soul: without the held thread, his reply
    # there would route nowhere.
    hub_ts = SlackPost.find_by(channel_id: HUB, thread_ts: nil, kind: "release").ts
    hub = ingest.send(:route, { "channel" => HUB, "ts" => "1762000099.000002", "thread_ts" => hub_ts,
                                "user" => OWNER, "text" => "anything to watch?" })
    assert_equal [ "steffon", "thread" ], [ hub.soul, hub.routed_by ]
  end

  test "[integration] a re-run sends nothing already posted" do
    release = shipped_release!
    transport = FakeTransport.new
    announce(release, transport)
    sent = transport.calls.size

    again = announce(release, transport)
    assert_equal sent, transport.calls.size
    assert_equal "Slack posts: 0 sent / 0 failed (7 already)", again.line
    assert_equal 3, AgentMessage.where(routed_by: "release").count
  end

  test "[integration] a Slack failure on one post is reported, never raised, and the other posts still go" do
    transport = FakeTransport.new(fail_channel: GENERAL, error: Net::ReadTimeout)
    result = nil
    assert_nothing_raised { result = announce(shipped_release!, transport) }

    assert_equal 1, result.failed
    assert_equal 6, result.sent
    general = result.posts.find { |p| p[:what] == "general" }
    assert_match(/Ambiguous/, general[:error])
    assert_equal "Slack posts: 6 sent / 1 failed", result.line
  end

  test "[integration] a repo with no Slack channel is skipped and logged, not raised" do
    release = shipped_release!
    task!("Engine Footer Tweak Here", [ "studio-engine" ]).update_columns(release_slug: release.slug)
    result = announce(release, FakeTransport.new)

    engine = result.posts.find { |p| p[:what] == "studio-engine" }
    assert_nil engine, "a library has no app post"
    assert_includes ReleaseNotes::SlackAnnouncement.new(release: release).general_text, "(library)"
  end

  test "[unit] a dry run posts nothing and writes nothing" do
    transport = FakeTransport.new
    result = announce(shipped_release!, transport, dry_run: true)

    assert_empty transport.calls
    assert_equal 0, SlackPost.count
    assert_equal %w[dry_run], result.posts.map { |p| p[:status] }.uniq
  end

  test "[unit] Release::Conductor.announce_release never raises into a ship" do
    release = shipped_release!
    ReleaseNotes::SlackAnnouncement.stub(:new, ->(**) { raise "boom" }) do
      result = Release::Conductor.announce_release(release: release)
      assert_equal 1, result[:failed]
      assert_match(/Slack posts: 0 sent \/ 1 failed \(RuntimeError: boom\)/, result[:line])
    end
  end
end

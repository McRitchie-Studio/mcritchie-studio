require "test_helper"
require_relative "../support/daily_app_report_fixtures"

# [unit] CtoReport: which apps get a CTO report, one key per app per Denver
# date, the skips (not wired, already posted), the shared health memo and the
# hub's board facts. The fetcher and ReportDestinations are fakes.
class CtoReportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DailyAppReportFixtures

  ENDING = Time.find_zone("America/Denver").local(2026, 10, 15, 7)

  setup do
    @hub = app_entry("mcritchie-studio", name: "McRitchie Studio")
    @turf = app_entry("turf-monster", name: "Turf Monster")
    @cyvasse = app_entry("cyvasse", name: "Cyvasse")
    @apps = [ @hub, @turf, @cyvasse ]
  end

  def entries(apps = @apps) = CtoReport.entries(apps: apps)

  def capture_deliveries(status: :posted)
    calls = []
    deliver = lambda do |key, content:, embeds:, idempotency_key:|
      calls << { key: key, content: content, embeds: embeds, idempotency_key: idempotency_key }
      ReportDestinations::Result.new(status: status, url: status == :posted ? "https://discord.com/channels/1/2/3" : nil,
                                     reason: status == :posted ? nil : "probe")
    end
    ReportDestinations.stub(:deliver, deliver) { yield calls }
  end

  def logger_into(lines)
    logger = Logger.new(nil)
    %i[info warn].each { |level| logger.define_singleton_method(level) { |msg = nil, &_| lines << msg } }
    logger
  end

  test "[unit] the configured CTOs: Avi for the hub, Turf for Turf Monster, Tyrion for Cyvasse, one registered key each" do
    list = entries
    assert_equal [ %w[cto_report:mcritchie_studio mcritchie-studio avi], %w[cto_report:turf_monster turf-monster turf_monster],
                   %w[cto_report:cyvasse cyvasse tyrion] ], list.map { |e| [ e.report_key, e.app.slug, e.soul ] }
    list.each { |e| assert ReportDestinations.registered?(e.report_key), "#{e.report_key} must be in config/report_destinations.yml" }
    CtoReport.config.each_key { |domain| assert ReportDestinations.registered?("cto_report:#{domain}"), domain }
    assert_equal "cto_report:turf_monster:2026-10-15", list[1].idempotency_key(ENDING)
    # 21:00 Denver is already tomorrow in UTC: still the 15th.
    assert_equal "cto_report:turf_monster:2026-10-15", list[1].idempotency_key(Time.utc(2026, 10, 16, 3))
  end

  test "[unit] against the real catalog every configured app is a live engine app" do
    assert_equal %w[mcritchie-studio turf-monster cyvasse], CtoReport.entries.map { |e| e.app.slug }
  end

  test "[unit] an unannounced app, an internal domain, and an app off the live list never report" do
    welding = app_entry("commercial-welding", name: "Commercial Welding")
    config = { "commercial_welding" => { "app" => "commercial-welding", "soul" => "avi" },
               "secret_shop" => { "app" => "turf-monster", "soul" => "turf_monster" },
               "rantly" => { "app" => "rantly", "soul" => "avi" },
               "turf_monster" => { "app" => "turf-monster", "soul" => "turf_monster" } }

    list = CtoReport.entries(config: config, apps: @apps + [ welding ], internal: %w[secret_shop])

    assert_equal %w[turf_monster], list.map(&:domain)
    assert_includes CtoReport.internal_domains, "commercial_welding"
    assert_empty CtoReport.entries(config: { "commercial_welding" => { "app" => "turf-monster", "soul" => "avi" } }, apps: @apps)
  end

  test "[unit] one run: a report per wired app under its own key; an unwired app is a logged skip with no delivery" do
    lines = []
    fetcher = FakeFetcher.new(@turf.production_url => health_body(signups: 2))
    capture_deliveries do |calls|
      results = CtoReport.run(ending: ENDING, fetcher: fetcher, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" },
                              logger: logger_into(lines), entries: entries)

      assert_equal %w[cto_report:mcritchie_studio cto_report:turf_monster], calls.map { |c| c[:key] }
      assert_equal %w[cto_report:mcritchie_studio:2026-10-15 cto_report:turf_monster:2026-10-15], calls.map { |c| c[:idempotency_key] }
      assert_includes calls.first[:content], "On the board:"
      assert_includes calls.last[:content], "2 signups, and zero errors."
      assert_equal :not_wired, results["cto_report:cyvasse"]
    end
    assert_includes lines, "[cto-report] cto_report:cyvasse:2026-10-15 skipped: cyvasse is not wired (no HEALTH_TOKEN_CYVASSE)"
    assert_equal 1, fetcher.calls.size
  end

  test "[integration] each report carries its own domain's answers in the window, and only those" do
    turf_answer = AgentMessage.create!(channel: "discord", external_id: "cto-usage-1", channel_ref: "c", thread_key: "t1",
                                       soul_slug: "turf_monster", status: "completed", completed_at: ENDING - 2.hours,
                                       content: "x", run_meta: { "input_tokens" => 40, "output_tokens" => 2, "duration_ms" => 1_500 })
    AgentMessage.create!(channel: "discord", external_id: "cto-usage-2", channel_ref: "c", thread_key: "t2",
                         soul_slug: "turf_monster", status: "completed", completed_at: ENDING - 2.days, content: "x",
                         run_meta: { "input_tokens" => 999 })
    fetcher = FakeFetcher.new(@turf.production_url => health_body(signups: 2))
    capture_deliveries do |calls|
      CtoReport.run(ending: ENDING, fetcher: fetcher, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" }, logger: logger_into([]),
                    entries: entries)
      turf = calls.find { |c| c[:key] == "cto_report:turf_monster" }[:content]
      hub = calls.find { |c| c[:key] == "cto_report:mcritchie_studio" }[:content]
      assert_includes turf, "Agent usage, the day: 1 answer, 42 tokens (in 40 · cache read 0 · cache write 0 · out 2), $0.00, avg 1.5s."
      assert_includes hub, "Agent usage, the day: no answers."
    end
    assert turf_answer.persisted?
  end

  test "[unit] the shared memo: an app the combined report already read is not fetched again" do
    fetcher = FakeFetcher.new({})
    read = DailyAppReport.from_json(@turf, health_body(errors: 3, groups: [ [ "Foo", "x", 3 ] ]))
    capture_deliveries do |calls|
      CtoReport.run(ending: ENDING, fetcher: fetcher, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" },
                    healths: { "turf-monster" => read }, entries: entries([ @turf ]))
      assert_includes calls.sole[:content], "3 errors in 1 kind."
    end
    assert_empty fetcher.calls
  end

  test "[unit] a day already posted is neither fetched nor delivered again" do
    e = entries([ @turf ]).sole
    ReportDelivery.create!(report_key: e.report_key, idempotency_key: e.idempotency_key(ENDING), status: "posted")
    fetcher = FakeFetcher.new({})
    capture_deliveries do |calls|
      result = CtoReport.run(ending: ENDING, fetcher: fetcher, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" }, entries: [ e ])
      assert_equal :posted, result[e.report_key].status
      assert_empty calls
    end
    assert_empty fetcher.calls
  end

  test "[unit] a destination with no channel is a logged skip, not an error, not retried" do
    lines = []
    capture_deliveries(status: :not_configured) do
      assert_no_enqueued_jobs(only: ReportDeliveryJob) do
        assert_no_difference -> { ErrorLog.count } do
          CtoReport.run(ending: ENDING, fetcher: FakeFetcher.new({}), env: {}, logger: logger_into(lines), entries: entries([ @hub ]))
        end
      end
    end
    assert_includes lines, "[cto-report] cto_report:mcritchie_studio:2026-10-15 status=not_configured reason=probe"
  end

  test "[unit] a Discord failure hands the same message and key to ReportDeliveryJob" do
    capture_deliveries(status: :failed) do
      assert_enqueued_with(job: ReportDeliveryJob) do
        CtoReport.run(ending: ENDING, fetcher: FakeFetcher.new({}), env: {}, entries: entries([ @hub ]))
      end
    end
    args = enqueued_jobs.find { |j| j["job_class"] == "ReportDeliveryJob" }["arguments"]
    assert_equal "cto_report:mcritchie_studio", args.first
  end

  test "[unit] one app's crash is an ErrorLog row and the next app still reports" do
    boom = Class.new { def fetch(*, **) = raise(ArgumentError, "probe") }.new
    capture_deliveries do |calls|
      assert_difference -> { ErrorLog.count }, 1 do
        results = CtoReport.run(ending: ENDING, fetcher: boom, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" },
                                entries: entries([ @turf, @hub ]))
        assert_kind_of ArgumentError, results["cto_report:turf_monster"]
      end
      assert_equal %w[cto_report:mcritchie_studio], calls.map { |c| c[:key] }
    end
  end

  test "[unit] an unreachable app still reports, saying why" do
    fetcher = FakeFetcher.new(@turf.production_url => DailyAppReport::Fetcher::Error.new("HTTP 401 token mismatch"))
    capture_deliveries do |calls|
      CtoReport.run(ending: ENDING, fetcher: fetcher, env: { "HEALTH_TOKEN_TURF_MONSTER" => "t" }, entries: entries([ @turf ]))
      assert_includes calls.sole[:content], "No feed from the app today (HTTP 401 token mismatch), so no box score."
      assert_empty calls.sole[:embeds]
    end
  end

  test "[unit] hub facts: open-stage counts, blocks, shipped inside the window only, the release in flight" do
    Task.delete_all
    Release.delete_all
    make = ->(slug, stage, **attrs) { Task.create!({ slug: slug, title: slug.titleize, stage: stage }.merge(attrs)) }
    make.("a-one", "designed")
    make.("a-two", "building", blocked_at: Time.current)
    make.("a-three", "submitted")
    make.("a-four", "assembled")
    make.("a-five", "archived")
    shipped_in = make.("a-six", "shipped")
    shipped_out = make.("a-seven", "shipped")
    shipped_in.update_columns(completed_at: ENDING - 3.hours)
    shipped_out.update_columns(completed_at: ENDING - 30.hours)
    # Shipped in the window, then archived when a later release shipped: still counted.
    make.("a-eight", "archived").update_columns(completed_at: ENDING - 5.hours)
    release = Release.create!(state: "assembled", assembled_at: Time.current)
    Task.where(slug: "a-four").update_all(release_slug: release.slug)

    facts = CtoReport.board_facts(ENDING)

    assert_equal({ "designed" => 1, "building" => 1, "submitted" => 1, "reviewed" => 0, "assembled" => 1 }, facts.stages)
    assert_equal [ 2, 1, 1, 1, 2 ], [ facts.building, facts.in_review, facts.deploying, facts.blocked, facts.shipped ]
    assert_equal({ stage: "assembled", tasks: 1 }, facts.release)
  end
end

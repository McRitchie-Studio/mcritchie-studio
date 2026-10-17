# frozen_string_literal: true

require "test_helper"

# [component] The pipeline page in isolation (docs/agents/system/client-pipeline.md):
# handed a Pipeline directly, it draws the six lanes, the lane meter and its words,
# the queue numbers, the on-hold chip and the Tonight's ship preview, and only an
# admin's render carries task and PR links.
class ClientPipelineViewTest < ActionView::TestCase
  include ApplicationHelper
  include StatusToneHelper

  def lane(key) = ClientPipeline::LANES.find { |l| l.key == key }

  def pipeline(tier: "pro", in_use: 2, release: nil, admin: false)
    app = apps(:turf_monster)
    building = ClientPipeline::Card.new(title: "Wire the scores", lane: "Building", entered_at: 2.hours.ago, role: "Builder",
                                        on_hold: true, slug: ("wire-the-scores" if admin), pr_url: ("https://github.com/x/y/pull/1" if admin))
    queued = [ 1, 2 ].map { |n| ClientPipeline::Card.new(title: "Queued #{n}", lane: "Queued", entered_at: n.days.ago, queue_position: n, on_hold: false, slug: ("queued-#{n}" if admin)) }
    lanes = ClientPipeline::LANES.map do |l|
      cards = { "building" => [ building ], "queued" => queued }.fetch(l.key, [])
      ClientPipeline::LaneView.new(lane: l, cards: cards)
    end
    status = BuildingLanes::Status.new(app: app, package: tier && WorkspacePackage.find(tier), in_use: in_use)
    ClientPipeline::Pipeline.new(app: app, lanes: lanes, lanes_status: status, release: release)
  end

  def draw(admin: false, **opts)
    @app = apps(:turf_monster)
    @admin = admin
    @pipeline = pipeline(admin: admin, **opts)
    render template: "applications/pipeline"
  end

  test "[component] six lanes in order, the lane meter, queue numbers and the hold chip" do
    draw
    assert_equal %w[queued building review ready qa shipped], css_select("[data-test='pipeline-lane']").map { |el| el["data-lane"] }
    assert_select "[data-test='pipeline-lanes-label']", text: "2 of 3 lanes in use"
    assert_select "[data-test='pipeline-lanes'][data-cap='3'][data-in-use='2']"
    assert_select "[data-test='pipeline-card-queue']", [ "#1", "#2" ].size
    assert_select "[data-test='pipeline-card-hold']", text: "On hold"
    assert_select "[data-test='pipeline-lane'][data-lane='building'] [data-test='pipeline-card-age']", text: "about 2 hours building"
    assert_select "[data-test='pipeline-lane'][data-lane='queued'] [data-test='pipeline-card-age']", text: "1 day in the queue"
    assert_select "[data-test='pipeline-lane'][data-lane='review'] [data-test='pipeline-lane-empty']"
    assert_select "[data-test='pipeline-card-admin']", count: 0
    assert_select "[data-test='pipeline-tonight']", text: /No release is in progress/
  end

  test "[component] an unlimited tier, a release in progress, and an admin's links" do
    draw(tier: "enterprise", in_use: 5, admin: true, release: ClientPipeline::ReleaseView.new(state: "assembled", count: 2))
    assert_select "[data-test='pipeline-lanes-label']", text: "5 lanes in use"
    assert_select "[data-test='pipeline-lanes']", text: /no lane limit/
    assert_select "[data-test='pipeline-tonight']", text: /on QA, green and ready to ship, carrying 2 of your tasks/
    assert_select "[data-test='pipeline-card-pr'][href='https://github.com/x/y/pull/1']"
    assert_select "a[href='/tasks/wire-the-scores']"
  end

  test "[component] an uncapped internal app says so to an admin" do
    draw(tier: nil, in_use: 1, admin: true)
    assert_select "[data-test='pipeline-lanes-uncapped']"
  end

  test "[component] an uncapped app's owner sees no internal-app line" do
    draw(tier: nil, in_use: 1, admin: false)
    assert_select "[data-test='pipeline-lanes-label']", text: "1 lane in use"
    assert_select "[data-test='pipeline-lanes-uncapped']", count: 0
  end

  # Shannon's notes on client-devops-view-lanes: a screen reader hears what each
  # chip means, the meter shows work past the cap, and a release with none of the
  # app's tasks says so in words.
  test "[component] the lane count and queue chips carry screen-reader words" do
    draw
    assert_select "[data-test='pipeline-lane'][data-lane='queued'] [data-test='pipeline-lane-count'] .sr-only", text: "2 tasks"
    assert_select "[data-test='pipeline-lane'][data-lane='building'] [data-test='pipeline-lane-count'] .sr-only", text: "1 task"
    assert_select "[data-test='pipeline-lane'][data-lane='review'] [data-test='pipeline-lane-count'] .sr-only", text: "0 tasks"
    assert_select "[data-test='pipeline-lane-count'] [aria-hidden='true']", ClientPipeline::LANES.size
    assert_select "[data-test='pipeline-card-queue'] .sr-only", text: "Queue position", count: 2
  end

  test "[component] an overfilled meter draws the lanes past the cap and says why" do
    draw(tier: "builder", in_use: 3)
    assert_select "[data-test='pipeline-lanes-label']", text: "3 lanes in use on a 2-lane plan"
    assert_select "[data-test='pipeline-lanes-meter'] span", 3
    assert_select "[data-test='pipeline-lanes-over']", 1
    assert_select "[data-test='pipeline-lanes-over-note']", text: /sent back for changes keeps its lane/
  end

  test "[component] a full meter at the cap draws no over segment" do
    draw(tier: "builder", in_use: 2)
    assert_select "[data-test='pipeline-lanes-label']", text: "2 of 2 lanes in use"
    assert_select "[data-test='pipeline-lanes-meter'] span", 2
    assert_select "[data-test='pipeline-lanes-over']", 0
    assert_select "[data-test='pipeline-lanes-over-note']", 0
  end

  test "[component] a release with none of the app's tasks reads none, not 0 of" do
    draw(release: ClientPipeline::ReleaseView.new(state: "assembled", count: 0))
    assert_select "[data-test='pipeline-tonight']", text: /carrying none of your tasks\./
    assert_select "[data-test='pipeline-tonight']", text: /0 of your tasks/, count: 0
  end
end

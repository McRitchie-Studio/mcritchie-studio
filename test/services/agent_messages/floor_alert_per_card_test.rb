require "test_helper"

# [unit] The floor alert's two per-card checks (AgentMessages::FloorAlert):
#
#   submitted_unclaimed   a submitted card, DoR green, no review claim for 30 min:
#                         one incident naming the slug, one ops post carrying the
#                         review launch line, one recovery when a claim appears or
#                         the card leaves submitted. Controls: a red DoR, a card
#                         submitted 29 min ago, and a live claim open nothing.
#   change_build_refused  a designed change card the launcher could not start: one
#                         incident per card, recovered when the start succeeds.
#
# Discord is a recording transport; nothing leaves the process.
class AgentMessages::FloorAlertPerCardTest < ActiveSupport::TestCase
  OPS = "900000000000000778".freeze

  class Recorder
    attr_reader :posts

    def initialize = @posts = []

    def call(_method, _url, _headers, body)
      @posts << JSON.parse(body)["content"]
      [ 200, JSON.generate("id" => "1#{@posts.size}") ]
    end
  end

  setup do
    @recorder = Recorder.new
    bot = AgentMessages::DiscordBot.new(token: "test-token", transport: @recorder)
    routes = AgentMessages::Routes.new("discord" => { "ops_channel_id" => OPS, "guilds" => {} })
    @floor = AgentMessages::FloorAlert.new(routes: routes, bot: bot, logger: Logger.new(nil))
    @t0 = Time.current
  end

  def submitted!(slug, at: @t0 - 31.minutes, dor: true)
    task = Task.create!(title: "Card #{slug}", slug: slug, stage: "designed", priority: 1)
    task.update_columns(stage: "submitted", submitted_at: at, pr_url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/9#{task.id}")
    unless dor.nil?
      GateRun.create!(subject_type: "task", subject_slug: slug, key: "dor", attempt: 1, started_at: at, finished_at: at,
                      success: dor)
    end
    task
  end

  def claim!(slug, at: @t0)
    TaskReviewClaim.create!(task_slug: slug, acquired_at: at, claim_expires_at: at + 3.hours, holder_agent: "carl",
                            claimed_session: "s-1", claim_nonce: "n-1")
  end

  def unclaimed = AgentMailboxIncident.where(kind: "submitted_unclaimed")

  test "a green-DoR card unclaimed for 30 minutes opens one incident naming it and posts the launch line once" do
    submitted!("waits-for-review")

    @floor.call(now: @t0)
    @floor.call(now: @t0 + 1.minute)

    incident = unclaimed.sole
    assert_equal "waits-for-review", incident.subject
    assert incident.open?
    assert_equal 1, @recorder.posts.size, "one alert per card, not one a minute"
    text = @recorder.posts.first
    assert_match(/Review not started: `waits-for-review` has sat submitted with a green DoR and no review claim for 31 min/, text)
    assert_includes text, "bin/task review-claim acquire waits-for-review --agent carl"
    assert_includes text, "SOP pr-review, single-task entry"
  end

  test "a review claim recovers the incident, and the recovery posts once" do
    submitted!("gets-claimed")
    @floor.call(now: @t0)

    claim!("gets-claimed", at: @t0 + 2.minutes)
    @floor.call(now: @t0 + 3.minutes)
    @floor.call(now: @t0 + 4.minutes)

    incident = unclaimed.sole
    refute incident.open?
    assert_equal 2, @recorder.posts.size
    assert_match(/`gets-claimed` no longer waits for review/, @recorder.posts.last)
  end

  test "a card that leaves submitted recovers its incident" do
    task = submitted!("gets-merged")
    @floor.call(now: @t0)
    task.update_columns(stage: "reviewed")

    @floor.call(now: @t0 + 1.minute)

    refute unclaimed.sole.open?
  end

  test "controls: a red DoR, no DoR, 29 minutes, a live claim, a blocked card and a recently released claim open nothing" do
    submitted!("red-dor", dor: false)
    submitted!("no-dor", dor: nil)
    submitted!("too-soon", at: @t0 - 29.minutes)
    submitted!("under-review")
    claim!("under-review", at: @t0 - 40.minutes)
    submitted!("blocked-card").update_columns(blocked_at: @t0 - 1.hour)
    submitted!("just-released")
    # TaskReviewClaim.drop nils the lease fields on release; only updated_at dates it.
    TaskReviewClaim.create!(task_slug: "just-released", updated_at: @t0 - 5.minutes)

    checks = @floor.call(now: @t0)

    assert_empty unclaimed
    assert_empty checks.select { |c| c.kind == "submitted_unclaimed" }
    assert_empty @recorder.posts
  end

  test "a claim released over 30 minutes ago no longer holds the alert back" do
    submitted!("released-long-ago")
    TaskReviewClaim.create!(task_slug: "released-long-ago", updated_at: @t0 - 31.minutes)

    @floor.call(now: @t0)

    assert_equal %w[released-long-ago], unclaimed.unresolved.pluck(:subject)
  end

  test "two waiting cards are two incidents, each resolving on its own" do
    submitted!("first-card")
    submitted!("second-card")
    @floor.call(now: @t0)
    assert_equal %w[first-card second-card], unclaimed.unresolved.order(:subject).pluck(:subject)

    claim!("first-card")
    @floor.call(now: @t0 + 1.minute)

    assert_equal %w[second-card], unclaimed.unresolved.pluck(:subject)
    assert_equal 3, @recorder.posts.size, "two alerts and one recovery"
  end

  test "a per-card incident never shares the floor-wide kinds' one-open-per-kind slot" do
    submitted!("beside-floor")
    AgentMailboxIncident.create!(kind: "message_waiting", detail: {}, opened_at: @t0)

    @floor.call(now: @t0)

    assert unclaimed.sole.open?
    assert_raises(ActiveRecord::RecordInvalid) { AgentMailboxIncident.create!(kind: "submitted_unclaimed", detail: {}, opened_at: @t0) }
    assert_raises(ActiveRecord::RecordInvalid) { AgentMailboxIncident.create!(kind: "message_waiting", subject: "x", detail: {}, opened_at: @t0) }
  end

  test "a refused change build opens one incident naming the card, and a started build recovers it" do
    task = Task.create!(title: "Dark toggle", slug: "dark-toggle", stage: "designed", priority: 1,
                        metadata: { "devops" => { "change_build" => { "state" => "refused", "attempts" => 1,
                                                                      "refused_reason" => "bin/task begin exited 1: no desk slot" } } })
    @floor.call(now: @t0)
    @floor.call(now: @t0 + 1.minute)

    incident = AgentMailboxIncident.where(kind: "change_build_refused").sole
    assert_equal "dark-toggle", incident.subject
    assert_equal 1, @recorder.posts.size
    assert_match(/Change build not started: .*`dark-toggle` \(bin\/task begin exited 1: no desk slot\)/, @recorder.posts.first)
    assert_includes @recorder.posts.first, "task begin dark-toggle --agent pokemon"

    task.update!(metadata: { "devops" => { "change_build" => { "state" => "started", "attempts" => 2 } } })
    @floor.call(now: @t0 + 2.minutes)

    refute incident.reload.open?
    assert_match(/`dark-toggle` no longer waits for its build/, @recorder.posts.last)
  end

  test "control: a designed card with no refusal opens no change_build_refused incident" do
    Task.create!(title: "Never refused", slug: "never-refused", stage: "designed", priority: 1,
                 metadata: { "devops" => { "change_build" => { "state" => "starting", "attempts" => 1 } } })

    @floor.call(now: @t0)

    assert_empty AgentMailboxIncident.where(kind: "change_build_refused")
  end
end

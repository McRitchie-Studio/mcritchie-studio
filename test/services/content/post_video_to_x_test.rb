require "test_helper"

# [unit] Content::PostVideoToX — the Post button's machine. What it will not
# post, that it posts ONCE, and that every way a run can end leaves the card
# telling the truth about whether a video is live.
class Content::PostVideoToXTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CREDS = %w[X_API_KEY X_API_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET].freeze

  # Stands in for X::PostMedia: records each post and answers as told.
  class FakeMedia
    class << self
      attr_accessor :posts, :outcome
    end

    def initialize(text:, video_path:)
      @text = text
      @bytes = File.size(video_path)
    end

    def call
      self.class.posts << [@text, @bytes]
      raise self.class.outcome if self.class.outcome.is_a?(Exception)

      { post_id: "777", post_url: "https://x.com/i/web/status/777" }
    end
  end

  class FakeReadBack
    def initialize(_id, **) = nil
    def call = { "video" => true, "seconds" => 27.7, "text" => "t" }
  end

  class FakeClient
    def initialize(username) = @username = username
    def get(*) = :response
    def parse_json(_) = { "data" => { "username" => @username } }
  end

  setup do
    @prior = CREDS.to_h { |k| [k, ENV[k]] }
    CREDS.each { |k| ENV[k] = "test" }
    FakeMedia.posts = []
    FakeMedia.outcome = nil
    @content = Content.create!(title: "Bills win", workflow: "video_post_x", stage: "script", team_slug: "buffalo-bills",
                               captions: "Bills 3-1 #nfl #billsmafia", final_video_url: "https://cdn.test/v.mp4")
  end

  teardown { @prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v } }

  def run_post(username: "turfmonstershow")
    service = Content::PostVideoToX.new(@content, media: FakeMedia, read_back: FakeReadBack, client: FakeClient.new(username))
    service.define_singleton_method(:download) { |_url, dest| File.write(dest, "video") }
    service.call
    @content.reload
  end

  def begin_post = perform_enqueued_jobs(only: []) { Content::PostVideoToX.begin!(@content) }

  test "names each reason a card cannot be posted" do
    assert_nil Content::PostVideoToX.refusal(@content)

    { { captions: "" } => "no copy", { stage: "idea" } => "no copy", { stage: "posted" } => "already posted",
      { stage: "assembly" } => "already in flight", { final_video_url: nil } => "no video",
      { captions: "a" * 281 } => "not postable: weighs 281" }.each do |change, reason|
      card = @content.dup.tap { |c| c.assign_attributes(change) }
      assert_includes Content::PostVideoToX.refusal(card), reason, change.inspect
    end

    ENV.delete("X_API_KEY")
    assert_includes Content::PostVideoToX.refusal(@content), "keys are not set"
    assert_includes Content::PostVideoToX.refusal(Content.new(workflow: "game_recap")), "only a Video Post"
  end

  test "begin! queues exactly one job and a second click is refused" do
    assert_enqueued_jobs 1, only: ContentPostVideoToXJob do
      Content::PostVideoToX.begin!(@content)
      error = assert_raises(Content::PostVideoToX::Refused) { Content::PostVideoToX.begin!(@content.reload) }
      assert_includes error.message, "already in flight"
    end
    assert_equal "assembly", @content.reload.stage
    assert_equal "queued", @content.game_facts.dig("post", "state")
  end

  test "the job posts the card's copy, records the link and the read-back" do
    begin_post
    run_post

    assert_equal [["Bills 3-1 #nfl #billsmafia", 5]], FakeMedia.posts
    assert_equal "posted", @content.stage
    assert_equal "x", @content.platform
    assert_equal "https://x.com/turfmonstershow/status/777", @content.post_url
    assert_equal "777", @content.post_id
    assert_equal "posted", @content.game_facts.dig("post", "state")
    assert_equal true, @content.game_facts.dig("post", "verified", "video")
  end

  test "a second run of the same job does not post again" do
    begin_post
    run_post
    @content.update_columns(stage: "assembly") # a re-delivered job finds the card mid-flight, state already past queued
    run_post

    assert_equal 1, FakeMedia.posts.size
  end

  test "a run that finds the card in posting, not queued, does not post" do
    begin_post
    @content.update!(game_facts: @content.game_facts.merge("post" => { "state" => "posting", "attempted_at" => Time.current.utc.iso8601 }))
    run_post

    assert_empty FakeMedia.posts
    assert_equal "assembly", @content.stage
  end

  test "a refusal from X hands the card back to ready with X's words" do
    begin_post
    FakeMedia.outcome = X::PostMedia::NotPosted.new("tweet create failed: 403 duplicate")
    run_post

    assert_equal "script", @content.stage
    assert_equal "refused", @content.game_facts.dig("post", "state")
    assert_includes @content.game_facts.dig("post", "error"), "403 duplicate"
    assert_nil Content::PostVideoToX.refusal(@content), "a refused card can be posted again"
  end

  test "an unknown failure leaves the card in flight, flagged as possibly live" do
    begin_post
    FakeMedia.outcome = Net::ReadTimeout.new
    run_post

    assert_equal "assembly", @content.stage
    assert_equal "unknown", @content.game_facts.dig("post", "state")
    assert Content::PostVideoToX.stuck?(@content)
    assert_nil @content.post_url
  end

  test "keys for another account post nothing" do
    begin_post
    run_post(username: "someoneelse")

    assert_empty FakeMedia.posts
    assert_equal "script", @content.stage
    assert_includes @content.game_facts.dig("post", "error"), "@someoneelse, not @turfmonstershow"
  end

  test "stuck? is false for a fresh attempt and true once it is old" do
    begin_post
    assert_not Content::PostVideoToX.stuck?(@content.reload)

    travel 11.minutes do
      assert Content::PostVideoToX.stuck?(@content)
    end
  end

  # Settling a card as "not there" lets Post run again, so a LIVE run must not
  # read as stuck: one that waited nine minutes in the queue is still uploading.
  test "a run that waited in the queue is timed from its start, not from the click" do
    begin_post
    post = @content.reload.game_facts["post"]
    travel 9.minutes
    @content.update!(game_facts: { "post" => post.merge("state" => "posting", "started_at" => Time.current.utc.iso8601) })

    travel 2.minutes
    assert_not Content::PostVideoToX.stuck?(@content), "11 minutes after the click, 2 into the run"
    travel 9.minutes
    assert Content::PostVideoToX.stuck?(@content)
  end

  test "the job is never retried, whatever escapes the service" do
    begin_post
    Content::PostVideoToX.stub(:new, ->(*) { raise "boom" }) do
      # The block form counts only jobs enqueued INSIDE it: a retry would be one.
      assert_no_enqueued_jobs only: ContentPostVideoToXJob do
        assert_nothing_raised { ContentPostVideoToXJob.perform_now(@content.slug) }
      end
    end
  end
end

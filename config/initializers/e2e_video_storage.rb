# frozen_string_literal: true

# THE E2E LANE'S STAND-IN BUCKET for an uploaded video, and its stand-in stitcher. Only in the test env, and
# only when the Playwright server sets E2E_FAKE_VIDEO_STORAGE=1: the upload is
# measured and dropped, and a fixed path comes back as its URL. No bucket is
# reached, which the test env has no credentials for.
if Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1"
  Rails.application.config.to_prepare do
    Content::AttachVideo.define_singleton_method(:store) { |key:, body:| "/e2e-uploads/#{key}?bytes=#{body.size}" }
    # A generated take (the recast round trip): measured and dropped the same way.
    MusicVideos::StoreTake.define_singleton_method(:store) { |key:, body:| "/e2e-uploads/#{key}?bytes=#{body.size}" }
    # The final stitch: the lane has no ffmpeg and no bucket, so "this hub can
    # stitch" is forced on and the stitcher is a stand-in that waits a moment
    # (long enough for the page to show the stitch in progress) and reports a
    # file of the planned length. The button, the request, the job, the
    # states and the page's poll are all real; the ffmpeg work is proven
    # against real ffmpeg in test/lib/music_videos/stitcher_test.rb.
    MusicVideos::Stitcher.define_singleton_method(:available?) { |**| true }
    stand_in = Object.new
    stand_in.define_singleton_method(:call) do |request, **|
      sleep 3
      length = request.fetch("takes").last.fetch("end_ms")
      Struct.new(:report).new({ "duration_ms" => length, "byte_size" => 2_048_000, "width" => 320, "height" => 180,
                                "frame_rate" => "12", "warnings" => [] })
    end
    MusicVideos::RunStitch.define_singleton_method(:stitcher) { stand_in }
    # The test adapter only records jobs; run the stitch in-process so the
    # page can reach done. Scoped to this one job.
    StitchVideoJob.queue_adapter = :async
  end
end

# THE SAME LANE'S STAND-IN FOR ESPN. The draft on a Video Post (X) card reads a
# team's live record; the test env must not depend on a live sports feed or on
# what a real team's record happens to be today. Every team gets the same fixed
# season: 3-1, with a win yesterday afternoon.
if Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1"
  Rails.application.config.to_prepare do
    Content::DraftXCopy.fetch = lambda do |url|
      teams = Team.where(league: "nfl").order(:name).each_with_index.map { |t, i| { "team" => { "id" => (i + 1).to_s, "displayName" => t.name } } }
      case url
      when %r{/teams\z}          then { "sports" => [{ "leagues" => [{ "teams" => teams }] }] }
      when %r{/teams/(\d+)\z}    then { "team" => { "record" => { "items" => [{ "summary" => "3-1" }] } } }
      when %r{/teams/(\d+)/schedule\z}
        id = Regexp.last_match(1)
        { "events" => [{ "date" => 1.day.ago.utc.change(hour: 17).strftime("%Y-%m-%dT%H:%MZ"), "shortName" => "E2E @ HOME",
                         "competitions" => [{ "neutralSite" => false, "status" => { "type" => { "completed" => true } },
                                              "competitors" => [
                                                { "winner" => true, "score" => { "displayValue" => "27" }, "team" => { "id" => id } },
                                                { "winner" => false, "score" => { "displayValue" => "20" }, "team" => { "id" => "0", "displayName" => "E2E Opponent" } }
                                              ] }] }] }
      end
    end
  end
end

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

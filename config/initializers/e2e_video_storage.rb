# frozen_string_literal: true

# THE E2E LANE'S STAND-IN BUCKET for an uploaded video. Only in the test env, and
# only when the Playwright server sets E2E_FAKE_VIDEO_STORAGE=1: the upload is
# measured and dropped, and a fixed path comes back as its URL. No bucket is
# reached, which the test env has no credentials for.
if Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1"
  Rails.application.config.to_prepare do
    Content::AttachVideo.define_singleton_method(:store) { |key:, body:| "/e2e-uploads/#{key}?bytes=#{body.size}" }
  end
end

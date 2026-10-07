# frozen_string_literal: true

# The alt video asset zips read R2 and sheet hosts everywhere except the test
# env, where minitest and the e2e lane read synthetic bytes instead.
Rails.application.config.to_prepare do
  MusicVideos::AssetZip.fetcher = MusicVideos::AssetZip::FixtureFetcher.new if Rails.env.test?
end

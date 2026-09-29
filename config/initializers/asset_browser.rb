# frozen_string_literal: true

# /assets reads the live object store everywhere except the test env, where
# minitest and the e2e lane browse a fixture listing instead.
Rails.application.config.to_prepare do
  if Rails.env.test?
    AssetBrowser.source = AssetBrowser::FixtureSource.new(Rails.root.join("test/fixtures/files/asset_browser_listing.yml"))
  end
end

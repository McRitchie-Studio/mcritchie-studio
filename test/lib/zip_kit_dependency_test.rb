# frozen_string_literal: true

require "test_helper"

# [unit] The alt video asset zips (MusicVideos::AssetZip::Writer) lean on
# zip_kit 6.3.6: write_stored_file rolls a half-written entry out of the
# central directory when its block raises (a file that fails part way), and
# before 6.3.6 the end of central directory record still counted the rolled
# back entry, so the zip was unreadable to any reader that checks the count
# (ZipKit::FileReader among them; CHANGELOG 6.3.6). The lock pins 6.3.6, but a
# Gemfile of "~> 6.3" would let a `bundle update` or a fresh resolve settle
# on 6.3.0-6.3.5. The Gemfile itself must refuse those.
class ZipKitDependencyTest < ActiveSupport::TestCase
  def requirement = Bundler.load.dependencies.find { |d| d.name == "zip_kit" }&.requirement

  test "the Gemfile requires zip_kit 6.3.6 or later" do
    assert requirement, "zip_kit is not a direct dependency"
    assert_not requirement.satisfied_by?(Gem::Version.new("6.3.5")), "zip_kit #{requirement} admits 6.3.5"
    assert requirement.satisfied_by?(Gem::Version.new("6.3.6"))
    assert_equal Gem::Version.new("6.3.6"), Bundler.load.specs.find { |s| s.name == "zip_kit" }.version, "the lock stays on 6.3.6"
  end
end

# frozen_string_literal: true

require "test_helper"
require "rake"

# [integration] The marketing-kit SOP's last step end to end (task marketing-kit-on-logos): `bin/rails
# logos:marketing_kit`, the command a publish prints, records the brand's Google kit, and /logos then shows it Up to
# date with its Open link; a later logo save flips it to Kit changed. Bad input is refused with nothing written.
class MarketingKitOnLogosTest < ActionDispatch::IntegrationTest
  URL = "https://drive.google.com/drive/folders/cw123"
  KEYS = %w[BRAND URL OWNER AT BY SAVED_AT].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("logos:marketing_kit")
    @task = Rake::Task["logos:marketing_kit"]
  end

  test "the stamp records the kit, /logos shows it, and a later logo save marks it changed" do
    kit = BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 7))
    out = run_task("BRAND" => "welding_v2", "URL" => URL, "OWNER" => "team@commercialwelding.llc",
                   "AT" => "2026-10-08T01:02:03Z", "BY" => "alex")
    assert_match "welding_v2 Google kit (team@commercialwelding.llc): Up to date (published 2026-10-08T01:02:03Z by alex, kit saved 2026-10-07T00:00:00Z)", out

    log_in_as(users(:alex))
    get logos_path
    assert_select "a[data-test='kit-chip'][data-kind='google'][data-brand='welding_v2'][data-status='current'][href=?]", URL
    assert_select "[data-test='kit-chip'][data-kind='google'][data-brand='welding_v2'] [data-test='kit-chip-name']", "team@commercialwelding.llc"

    kit.update!(saved_at: Time.utc(2026, 10, 9))
    get logos_path
    assert_select "[data-test='kit-chip'][data-kind='google'][data-brand='welding_v2'][data-status='changed'][aria-label=?]",
                  "Google kit team@commercialwelding.llc: Kit changed"
  end

  test "an unknown brand, a missing or non-Drive URL, or a bad time is refused and writes nothing" do
    [{ "BRAND" => "nope", "URL" => URL }, { "BRAND" => "welding_v2" },
     { "BRAND" => "welding_v2", "URL" => "https://example.com/x" },
     { "BRAND" => "welding_v2", "URL" => URL, "AT" => "not a time" }].each do |env|
      error = assert_raises(SystemExit, env.inspect) { run_task(env) }
      refute error.success?
    end
    assert_equal 0, BrandMarketingKit.count
  end

  private

  def run_task(vars)
    saved = KEYS.to_h { |key| [key, ENV[key]] }
    KEYS.each { |key| ENV[key] = vars[key] }
    @task.reenable
    capture_io { @task.invoke }.first
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end

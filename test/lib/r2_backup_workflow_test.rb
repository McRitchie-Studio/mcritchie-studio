# frozen_string_literal: true

# [unit] The nightly R2 backup workflow's matrix. Each row names an app and the
# stem of its two repo secrets (R2_BACKUP_<STEM>_ACCESS_KEY_ID / _SECRET_ACCESS_KEY).
# A stem that does not follow the app slug (upper-cased, dashes to underscores)
# reads an unset secret, and that app's backup then fails every night on a
# missing credential. The r2-backup SOP §6 states the convention; this holds it.

require "minitest/autorun"
require "yaml"

class R2BackupWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/r2-backup.yml", __dir__)

  def matrix
    YAML.safe_load_file(WORKFLOW).dig("jobs", "backup", "strategy", "matrix", "include")
  end

  def test_each_app_uses_the_secret_stem_its_slug_implies
    refute_empty matrix
    matrix.each do |row|
      assert_equal row["app"].upcase.tr("-", "_"), row["secret"], "#{row['app']} reads the wrong repo secrets"
    end
  end

  # GitHub delays top-of-hour schedules most; at "0 9" two nights started 5.5
  # and 8.3 hours late. Psych reads the bare `on:` key as true.
  def test_the_schedule_runs_off_the_hour
    crons = YAML.safe_load_file(WORKFLOW).dig(true, "schedule").map { |entry| entry["cron"] }
    refute_empty crons
    crons.each { |cron| refute_equal "0", cron.split.first, "#{cron} runs on the hour" }
  end

  # apt's rclone (1.60.1 on ubuntu-latest) exits 1 on every upload to R2 (a 501
  # after the PUT), reproduced 2026-09-29. The install must be a
  # pinned release whose zip is checksum-verified.
  def test_rclone_is_a_pinned_verified_release_not_apt
    step = YAML.safe_load_file(WORKFLOW).dig("jobs", "backup", "steps").find { |st| st["name"] == "Install rclone" }
    refute_nil step
    refute_match(/apt/, step["run"])
    assert_match(/\A\d+\.\d+\.\d+\z/, step.dig("env", "RCLONE_VERSION"))
    assert_operator Gem::Version.new(step.dig("env", "RCLONE_VERSION")), :>, Gem::Version.new("1.60.1")
    assert_match(/\A\h{64}\z/, step.dig("env", "RCLONE_SHA256"))
    assert_match(/sha256sum -c/, step["run"])
  end

  def test_the_apps_backed_up_nightly
    assert_equal %w[mcritchie-industries moms-app], matrix.map { |row| row["app"] }.sort
  end
end

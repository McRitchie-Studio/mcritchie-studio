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

  def test_the_apps_backed_up_nightly
    assert_equal %w[mcritchie-industries moms-app], matrix.map { |row| row["app"] }.sort
  end
end

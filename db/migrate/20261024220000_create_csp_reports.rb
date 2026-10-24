# Violation reports for the hub's Content-Security-Policy-Report-Only header
# (config/initializers/content_security_policy.rb, CspReportsController).
#
# One row per distinct violation: the fingerprint is the page path, the directive,
# the blocked URI and where the blocked code sits (source file and line). A repeat
# bumps `count` and `last_seen_at` instead of adding a row, so a page that trips the
# policy on every view stays one row and the table reads as "top offenders".
# CspReportRetentionJob deletes rows not seen for 30 days.
class CreateCspReports < ActiveRecord::Migration[8.1]
  def change
    create_table :csp_reports do |t|
      t.string :fingerprint, null: false
      t.string :document_path, null: false
      t.string :directive, null: false
      t.string :blocked_uri, null: false
      t.string :source_file
      t.integer :line_number
      t.string :sample
      t.string :disposition
      t.string :user_agent
      t.integer :count, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :csp_reports, :fingerprint, unique: true
    add_index :csp_reports, :last_seen_at
  end
end

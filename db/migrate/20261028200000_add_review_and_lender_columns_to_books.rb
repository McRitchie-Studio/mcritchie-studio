# frozen_string_literal: true

# The books review page and the lender package (task mack-finance-seat).
#
#   book_entries.classified_at   when a person (or a rule) last recorded what the
#                                line was; the /books page lists recent answers by it
#   book_closes.lender_*         the lender package's Sheet and PDF, kept beside the
#                                close's own so a re-run updates the same two files
#
# Backfill: lines a person already classified take their updated_at as the
# moment, the closest record there is. Rule-classified lines stay nil.
class AddReviewAndLenderColumnsToBooks < ActiveRecord::Migration[8.1]
  def up
    add_column :book_entries, :classified_at, :datetime
    add_index :book_entries, [ :entity, :classified_at ]
    add_column :book_closes, :lender_sheet_file_id, :string
    add_column :book_closes, :lender_pdf_file_id, :string
    add_column :book_closes, :lender_generated_at, :datetime

    execute <<~SQL.squish
      UPDATE book_entries SET classified_at = updated_at
      WHERE category IS NOT NULL AND classified_by IS NOT NULL AND classified_by NOT LIKE 'rule:%'
    SQL
  end

  def down
    remove_column :book_closes, :lender_generated_at
    remove_column :book_closes, :lender_pdf_file_id
    remove_column :book_closes, :lender_sheet_file_id
    remove_index :book_entries, [ :entity, :classified_at ]
    remove_column :book_entries, :classified_at
  end
end

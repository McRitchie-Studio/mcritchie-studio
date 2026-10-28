# frozen_string_literal: true

# THE BOOKS LEDGER (task studio-books-month-close; Alex McRitchie 2026-10-27: "a close
# the month SOP we can run with generates fresh artifacts to Google Drive for book
# keeping"). Three tables, one migration so `down` undoes all three:
#
#   book_statements  one bank statement, as filed: which entity and account, the period,
#                    the bank's own summary (opening, credits, debits, service charges,
#                    closing), and the Drive file it was read from. `source_sha256` is the
#                    PDF's digest, so the same statement dropped twice is recognised.
#   book_entries     one line of a statement. `amount_cents` is SIGNED (+ in, − out).
#                    `category` is a key in config/books.yml; null means unclassified, and
#                    a close with any unclassified entry is a DRAFT. `classified_by` says
#                    who decided: `rule:<name>`, or the person/agent who ran classify.
#   book_closes      one generated month close: the Drive ids of its Sheet and PDF, so a
#                    re-run updates the same files and every link Alex shared keeps working.
#                    `status` (draft | final) carries CHECK book_closes_status_known, created
#                    with the table (StringStates::UNCONSTRAINED says why it is not in REGISTRY).
#
# `entity` is a key in config/books.yml (e.g. `studio`), not a foreign key: the entities
# are configuration, like report destinations.
class CreateBooksTables < ActiveRecord::Migration[8.1]
  def change
    create_table :book_statements do |t|
      t.string :entity, null: false
      t.string :account_key, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.bigint :opening_cents, null: false
      t.bigint :credits_cents, null: false, default: 0
      t.bigint :debits_cents, null: false, default: 0
      t.bigint :service_charges_cents, null: false, default: 0
      t.bigint :closing_cents, null: false
      t.string :source_sha256, null: false
      t.string :source_name
      t.string :inbox_file_id
      t.string :drive_file_id
      t.timestamps
    end
    add_index :book_statements, %i[entity account_key period_start period_end], unique: true,
                                                                                 name: "index_book_statements_on_period"
    add_index :book_statements, %i[entity source_sha256], unique: true
    add_index :book_statements, :inbox_file_id

    create_table :book_entries do |t|
      t.references :book_statement, null: false, foreign_key: { on_delete: :cascade }
      t.string :entity, null: false
      t.string :account_key, null: false
      t.integer :position, null: false
      t.date :posted_on, null: false
      t.bigint :amount_cents, null: false
      t.string :section, null: false
      t.string :description, null: false
      t.string :category
      t.string :purpose
      t.string :classified_by
      t.text :note
      t.timestamps
    end
    add_index :book_entries, %i[book_statement_id position], unique: true
    add_index :book_entries, %i[entity posted_on]
    add_index :book_entries, %i[entity category]

    create_table :book_closes do |t|
      t.string :entity, null: false
      t.string :month, null: false
      t.string :status, null: false
      t.string :sheet_file_id
      t.string :pdf_file_id
      t.integer :unclassified_count, null: false, default: 0
      t.jsonb :summary, null: false, default: {}
      t.string :generated_by
      t.datetime :generated_at
      t.timestamps
    end
    add_index :book_closes, %i[entity month], unique: true
    add_check_constraint :book_closes, "status IN ('draft', 'final')", name: "book_closes_status_known"
  end
end

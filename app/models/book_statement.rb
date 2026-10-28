# frozen_string_literal: true

# One bank statement in the books, as Books::Intake filed it: the bank's own
# summary, and the Drive file it was read from. Its lines are BookEntry rows.
# SOP: docs/agents/agents/mack/sops/close-the-month.md.
class BookStatement < ApplicationRecord
  has_many :entries, -> { order(:position) }, class_name: "BookEntry", foreign_key: :book_statement_id,
                                              inverse_of: :statement, dependent: :delete_all

  validates :entity, :account_key, :period_start, :period_end, :source_sha256, presence: true

  scope :for_entity, ->(entity) { where(entity: entity.to_s) }

  # The movement the lines must add up to.
  def movement_cents = closing_cents - opening_cents

  def entries_reconcile? = entries.sum(:amount_cents) == movement_cents

  # "2026-09-01 to 2026-09-30", for operator output.
  def period_label = "#{period_start.iso8601} to #{period_end.iso8601}"
end

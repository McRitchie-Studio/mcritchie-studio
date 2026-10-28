# frozen_string_literal: true

# One line of a bank statement. `amount_cents` is signed: + money in, − money
# out. `category` is a key in config/books.yml; nil means nobody has said what
# the line was yet, and any such line keeps a month close a DRAFT.
class BookEntry < ApplicationRecord
  belongs_to :statement, class_name: "BookStatement", foreign_key: :book_statement_id, inverse_of: :entries

  validates :entity, :account_key, :posted_on, :section, :description, presence: true
  validates :amount_cents, numericality: { only_integer: true }

  scope :for_entity, ->(entity) { where(entity: entity.to_s) }
  scope :through, ->(date) { where(posted_on: ..date) }
  scope :unclassified, -> { where(category: nil) }
  scope :chronological, -> { order(:posted_on, :book_statement_id, :position) }

  def classified? = category.present?

  # The month as a number (202609): the ledger's Period column, which the
  # workbook's SUMIFS compare with < and <=.
  def period = (posted_on.year * 100) + posted_on.month
end

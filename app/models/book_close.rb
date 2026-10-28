# frozen_string_literal: true

# One generated month close for one entity. It keeps the Drive ids of the Sheet
# and the PDF, so a re-run updates the same files and every link Alex McRitchie
# has shared keeps working. `status` is final only when every check passed and
# no line was left unclassified.
class BookClose < ApplicationRecord
  STATUSES = %w[draft final].freeze

  validates :entity, presence: true
  validates :month, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }
  validates :status, inclusion: { in: STATUSES }

  def final? = status == "final"
end

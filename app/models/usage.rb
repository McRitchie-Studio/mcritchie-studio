class Usage < ApplicationRecord
  include Sluggable

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true

  validates :period_date, presence: true
  validates :period_type, presence: true

  # A rollup SUMS token counts across a period, so it reaches a column ceiling
  # sooner than any single row does. See IntegerColumnRange.
  clamps_integer_columns :tokens_in, :tokens_out

  scope :recent, -> { order(period_date: :desc) }
  scope :for_agent, ->(slug) { where(agent_slug: slug) }

  def name_slug
    [agent_slug, period_date, period_type, model].compact.join("-")
  end
end

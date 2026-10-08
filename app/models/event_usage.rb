# frozen_string_literal: true

# An agent's completed or failed event carries its usage: the model, both token
# counts and the cost. This is the one rule; ReleaseEvent's validation and the
# three event endpoints (Api::RequiresEventUsage) both ask it.
module EventUsage
  SOURCES = %w[api agent cli].freeze
  STATUSES = %w[completed failed].freeze
  FIELDS = %i[model tokens_in tokens_out cost].freeze

  module_function

  # The usage fields an event from `source` with `status` still owes. `values`
  # answers `[]` by field name: an attributes hash or a record.
  def missing(source:, status:, values:)
    return [] unless SOURCES.include?(source.to_s) && STATUSES.include?(status.to_s)

    FIELDS.select { |field| values[field].to_s.strip.empty? }
  end
end

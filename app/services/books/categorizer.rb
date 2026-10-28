# frozen_string_literal: true

module Books
  # The first config/books.yml rule that matches a line decides its category.
  # A rule with no category marks a line that always needs a person's answer
  # (a wire names no counterparty), and no rule at all leaves it for one too.
  module Categorizer
    Result = Struct.new(:category, :purpose, :classified_by, :note, keyword_init: true)

    module_function

    def call(entity, description:, amount_cents:)
      rule = entity.rules.find { |r| r.match?(description, amount_cents) }
      return Result.new(note: "no rule matched; needs an answer") if rule.nil?
      return Result.new(note: "rule #{rule.name}: needs an answer") if rule.category.nil?

      Result.new(category: rule.category, purpose: rule.purpose, classified_by: "rule:#{rule.name}")
    end
  end
end

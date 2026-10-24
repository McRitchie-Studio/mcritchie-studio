# What one consolidation of a domain's warm session wrote
# (AgentDomainSession#consolidate!): the soul's own summary of the turns it
# covered. The domain's next fresh session starts from the newest one, inside
# the prompt's untrusted fence, labelled as the soul's own notes. Only owner and
# team text ever reaches a warm session, so a summary carries no client or
# public text forward. Append-only: one row per (domain, generation).
class AgentDomainSummary < ApplicationRecord
  validates :domain, :text, presence: true
  validates :generation, numericality: { greater_than_or_equal_to: 1 }, uniqueness: { scope: :domain }
end

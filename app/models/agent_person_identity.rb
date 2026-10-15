# Where an AgentPerson speaks: one (platform, external_id), a Discord user id or,
# later, an email address. Unique on the pair (the index is the guard), so one id
# is always one person. Made by AgentPerson.resolve! or link_identity!.
class AgentPersonIdentity < ApplicationRecord
  PLATFORMS = %w[discord email].freeze

  belongs_to :person, class_name: "AgentPerson", foreign_key: :agent_person_id, inverse_of: :identities

  validates :platform, inclusion: { in: PLATFORMS }
  validates :external_id, presence: true
end

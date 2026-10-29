# One step of an AgentSetup, in the kit's order: who did it and when. Its
# words and buttons come from the kit (AgentSetups::Kits), keyed by `key`.
class AgentSetupStep < ApplicationRecord
  belongs_to :agent_setup, inverse_of: :steps

  validates :key, presence: true, uniqueness: { scope: :agent_setup_id }
  validates :position, numericality: { only_integer: true, greater_than: 0 }

  def done? = done_at.present?
end

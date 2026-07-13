class IndexAgentActivitiesOnModelAndOpenedAt < ActiveRecord::Migration[8.1]
  # The Model Pricing roster looks up, per model id, the most recent session that
  # used it — `where(model: ...).order(opened_at: :desc)`. Without a leading-model
  # index that's a full opened_at scan for every never-used model. This composite
  # turns each into a clean index seek.
  def change
    add_index :agent_activities, [:model, :opened_at]
  end
end

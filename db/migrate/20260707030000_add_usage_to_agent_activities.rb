class AddUsageToAgentActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_activities, :model, :string
    add_column :agent_activities, :tokens_in, :integer
    add_column :agent_activities, :tokens_out, :integer
    add_column :agent_activities, :cache_read_tokens, :integer
    add_column :agent_activities, :cost, :decimal, precision: 10, scale: 4
  end
end

class AddSupervisorAgentToAgentActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_activities, :supervisor_agent, :string
  end
end

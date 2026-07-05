class RenameAtomicTelemetryToAgentTaxonomy < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_keys_and_indexes

    rename_table :atomic_events, :agent_activities
    rename_table :atomic_actions, :agent_actions

    rename_column :agent_actions, :atomic_event_id, :agent_activity_id
    rename_column :action_grades, :atomic_action_id, :agent_action_id
    rename_column :action_grades, :atomic_event_id, :agent_activity_id

    add_agent_indexes_and_foreign_keys
  end

  def down
    remove_agent_foreign_keys_and_indexes

    rename_column :action_grades, :agent_activity_id, :atomic_event_id
    rename_column :action_grades, :agent_action_id, :atomic_action_id
    rename_column :agent_actions, :agent_activity_id, :atomic_event_id

    rename_table :agent_actions, :atomic_actions
    rename_table :agent_activities, :atomic_events

    add_atomic_indexes_and_foreign_keys
  end

  private

  def remove_foreign_keys_and_indexes
    remove_foreign_key :atomic_actions, :atomic_events if foreign_key_exists?(:atomic_actions, :atomic_events)
    remove_foreign_key :action_grades, :atomic_actions if foreign_key_exists?(:action_grades, :atomic_actions)
    remove_foreign_key :action_grades, :atomic_events if foreign_key_exists?(:action_grades, :atomic_events)

    remove_index :atomic_actions, name: "index_atomic_actions_on_atomic_event_id" if index_exists?(:atomic_actions, :atomic_event_id, name: "index_atomic_actions_on_atomic_event_id")
    remove_index :action_grades, name: "index_action_grades_on_atomic_action_id" if index_exists?(:action_grades, :atomic_action_id, name: "index_action_grades_on_atomic_action_id")
    remove_index :action_grades, name: "index_action_grades_on_atomic_event_id" if index_exists?(:action_grades, :atomic_event_id, name: "index_action_grades_on_atomic_event_id")
    remove_index :action_grades, name: "index_action_grades_on_atomic_action_id_and_grader" if index_exists?(:action_grades, [:atomic_action_id, :grader], name: "index_action_grades_on_atomic_action_id_and_grader")
    remove_index :action_grades, name: "index_action_grades_on_atomic_event_id_and_grader" if index_exists?(:action_grades, [:atomic_event_id, :grader], name: "index_action_grades_on_atomic_event_id_and_grader")
  end

  def remove_agent_foreign_keys_and_indexes
    remove_foreign_key :agent_actions, :agent_activities if foreign_key_exists?(:agent_actions, :agent_activities)
    remove_foreign_key :action_grades, :agent_actions if foreign_key_exists?(:action_grades, :agent_actions)
    remove_foreign_key :action_grades, :agent_activities if foreign_key_exists?(:action_grades, :agent_activities)

    remove_index :agent_actions, name: "index_agent_actions_on_agent_activity_id" if index_exists?(:agent_actions, :agent_activity_id, name: "index_agent_actions_on_agent_activity_id")
    remove_index :action_grades, name: "index_action_grades_on_agent_action_id" if index_exists?(:action_grades, :agent_action_id, name: "index_action_grades_on_agent_action_id")
    remove_index :action_grades, name: "index_action_grades_on_agent_activity_id" if index_exists?(:action_grades, :agent_activity_id, name: "index_action_grades_on_agent_activity_id")
    remove_index :action_grades, name: "index_action_grades_on_agent_action_id_and_grader" if index_exists?(:action_grades, [:agent_action_id, :grader], name: "index_action_grades_on_agent_action_id_and_grader")
    remove_index :action_grades, name: "index_action_grades_on_agent_activity_id_and_grader" if index_exists?(:action_grades, [:agent_activity_id, :grader], name: "index_action_grades_on_agent_activity_id_and_grader")
  end

  def add_agent_indexes_and_foreign_keys
    add_index :agent_actions, :agent_activity_id, name: "index_agent_actions_on_agent_activity_id"
    add_index :action_grades, :agent_action_id, name: "index_action_grades_on_agent_action_id"
    add_index :action_grades, :agent_activity_id, name: "index_action_grades_on_agent_activity_id"
    add_index :action_grades, [:agent_action_id, :grader],
              unique: true, name: "index_action_grades_on_agent_action_id_and_grader"
    add_index :action_grades, [:agent_activity_id, :grader],
              unique: true, where: "agent_activity_id IS NOT NULL",
              name: "index_action_grades_on_agent_activity_id_and_grader"

    add_foreign_key :agent_actions, :agent_activities, on_delete: :nullify
    add_foreign_key :action_grades, :agent_actions
    add_foreign_key :action_grades, :agent_activities, on_delete: :nullify
  end

  def add_atomic_indexes_and_foreign_keys
    add_index :atomic_actions, :atomic_event_id, name: "index_atomic_actions_on_atomic_event_id"
    add_index :action_grades, :atomic_action_id, name: "index_action_grades_on_atomic_action_id"
    add_index :action_grades, :atomic_event_id, name: "index_action_grades_on_atomic_event_id"
    add_index :action_grades, [:atomic_action_id, :grader],
              unique: true, name: "index_action_grades_on_atomic_action_id_and_grader"
    add_index :action_grades, [:atomic_event_id, :grader],
              unique: true, where: "atomic_event_id IS NOT NULL",
              name: "index_action_grades_on_atomic_event_id_and_grader"

    add_foreign_key :atomic_actions, :atomic_events, on_delete: :nullify
    add_foreign_key :action_grades, :atomic_actions
    add_foreign_key :action_grades, :atomic_events, on_delete: :nullify
  end
end

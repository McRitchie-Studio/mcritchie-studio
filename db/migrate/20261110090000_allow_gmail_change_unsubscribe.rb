# Lets GmailChange log the `unsubscribe` action
# (/tasks/gmail-one-click-unsubscribe): the check constraint is dropped and
# added again with the new value. Only the allowed list grows, so every
# existing row still passes; no row is read or written, and no data step is owed.
class AllowGmailChangeUnsubscribe < ActiveRecord::Migration[8.1]
  OLD = %w[read unread archive inbox spam not_spam label unlabel move filter].freeze
  NEW = (OLD + %w[unsubscribe]).freeze

  def up
    remove_check_constraint :gmail_changes, name: "gmail_changes_action_known"
    add_check_constraint :gmail_changes, constraint(NEW), name: "gmail_changes_action_known"
  end

  def down
    remove_check_constraint :gmail_changes, name: "gmail_changes_action_known"
    add_check_constraint :gmail_changes, constraint(OLD), name: "gmail_changes_action_known"
  end

  private

  def constraint(actions) = "action IN (#{actions.map { "'#{_1}'" }.join(', ')})"
end

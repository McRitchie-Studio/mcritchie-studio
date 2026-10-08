# A login request names its kind (an admin login or a harness key), and a
# long-lived session (a harness key, a client runtime key) carries the label the
# operator reads when revoking it: the machine, or the runtime.
class AddKindAndLabelToAgentLogins < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_login_requests, :kind, :string, null: false, default: "admin_login"
    add_column :agent_login_requests, :label, :string
    add_column :agent_sessions, :label, :string
  end
end

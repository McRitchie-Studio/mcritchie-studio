# The person a new Drive folder is shared with. Folders an agent makes are owned
# by a Workspace's team@ user, so nobody else can see them until they are shared.
# The three house Workspaces all answer to the same person today; a client's row
# gets its own value when it is registered.
class AddFolderUserEmailToWorkspaceAccounts < ActiveRecord::Migration[8.1]
  HOUSE_DOMAINS = %w[mcritchie.studio mcritchie.industries commercialwelding.llc].freeze

  def up
    add_column :workspace_accounts, :folder_user_email, :string

    execute <<~SQL.squish
      UPDATE workspace_accounts SET folder_user_email = 'alex@mcritchie.studio'
      WHERE domain IN (#{HOUSE_DOMAINS.map { |d| connection.quote(d) }.join(', ')})
    SQL
  end

  def down
    remove_column :workspace_accounts, :folder_user_email
  end
end

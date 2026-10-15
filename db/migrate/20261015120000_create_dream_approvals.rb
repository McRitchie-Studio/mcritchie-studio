# Alex's one-click approval of a proposed dream (docs/agents/modules/dream.md,
# Act 3). The dream bank is tracked files, so an approval is recorded here first
# and written into the file by the next batch task (`bin/dream apply-approvals`);
# /dreams stamps applied_at once the deployed file reads `status: approved`.
#
# A dream is keyed by its home directory and file slug, as the bank names it. The
# approver is a user slug (users.slug); a deleted user leaves the row standing.
class CreateDreamApprovals < ActiveRecord::Migration[8.1]
  def change
    create_table :dream_approvals do |t|
      t.string :dream_slug, null: false
      t.string :dream_home, null: false
      t.string :approved_by_slug
      t.datetime :approved_at, null: false
      t.datetime :applied_at
      t.timestamps
    end
    add_index :dream_approvals, [ :dream_home, :dream_slug ], unique: true
    add_index :dream_approvals, :applied_at
    add_foreign_key :dream_approvals, :users, column: :approved_by_slug, primary_key: :slug,
                                              on_update: :cascade, on_delete: :nullify
  end
end

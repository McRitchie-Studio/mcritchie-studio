# Who owns which app (docs/agents/system/app-owners.md; plan: Phase 6a of
# .agents/epics/domain-agents.md). An owner signs in to the hub and sets their
# app's CTO settings at /applications and /agents/:slug/settings. Ownership is
# this row, never users.role: the three owners below stay `viewer` (or admin)
# in the hub, and a membership grants only their own app's pages.
#
# Slug-keyed both ways, cascading on a slug rename (a user's slug moves with a
# name change) and on a delete. One row per (app, user).
#
# The data step seeds the three known owners where both rows exist, so the
# release phase (db:migrate) sets production up; AppMembership.seed_owners! is
# the same step for a re-seed and the task's post_deploy_cmd. Bare SQL, not the
# model, so this migration still runs after the model changes.
class CreateAppMemberships < ActiveRecord::Migration[8.1]
  OWNERS = {
    "mcritchie-studio" => "alex@mcritchie.studio",
    "turf-monster" => "alex@turfmonster.media",
    "cyvasse" => "amcritchie@gmail.com"
  }.freeze

  def up
    create_table :app_memberships do |t|
      t.string :app_slug, null: false
      t.string :user_slug, null: false
      t.string :role, null: false, default: "owner"
      t.timestamps
    end
    add_index :app_memberships, [ :app_slug, :user_slug ], unique: true
    add_index :app_memberships, :user_slug
    add_check_constraint :app_memberships, "role IN ('owner')", name: "app_memberships_role_known"
    add_foreign_key :app_memberships, :apps, column: :app_slug, primary_key: :slug, on_update: :cascade, on_delete: :cascade
    add_foreign_key :app_memberships, :users, column: :user_slug, primary_key: :slug, on_update: :cascade, on_delete: :cascade

    OWNERS.each do |app_slug, email|
      execute <<~SQL.squish
        INSERT INTO app_memberships (app_slug, user_slug, role, created_at, updated_at)
        SELECT apps.slug, users.slug, 'owner', NOW(), NOW()
        FROM apps, users
        WHERE apps.slug = #{quote(app_slug)} AND LOWER(users.email) = #{quote(email)} AND users.slug IS NOT NULL
        ON CONFLICT (app_slug, user_slug) DO NOTHING
      SQL
    end
  end

  def down
    drop_table :app_memberships
  end
end

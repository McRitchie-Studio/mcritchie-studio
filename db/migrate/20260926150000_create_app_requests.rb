# frozen_string_literal: true

# One app someone asked McRitchie Studio to build, from the /build funnel.
#
# A request starts as a DRAFT the moment the prompt is sent — before the visitor
# has an account — so nothing typed is lost to the sign-in detour. The draft is
# found again by its `token`, which rides the magic link's return_to (so it
# survives opening the email on another device). Signing in attaches the draft
# to its user; claiming a subdomain QUEUES it, which also opens a board task for
# an agent to build. Builds are asynchronous: status moves on as agents work.
#
# `subdomain` is unique among requests that hold one, so two people can never be
# promised the same <name>.mcritchie.studio.
class CreateAppRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :app_requests do |t|
      t.string :token, null: false
      t.references :user, foreign_key: true
      t.text :prompt, null: false
      t.string :subdomain
      t.string :status, null: false, default: "draft"
      t.string :tier, null: false, default: "launch"
      t.string :task_slug
      t.datetime :queued_at
      t.timestamps
    end
    add_index :app_requests, :token, unique: true
    add_index :app_requests, :subdomain, unique: true, where: "subdomain IS NOT NULL"
    add_index :app_requests, :status
  end
end

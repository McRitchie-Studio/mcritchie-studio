# frozen_string_literal: true

# One McRitchie Studio client, as /stack shows it: which tier they are on, which
# of their software we host for them, and the two details the page leads with
# (Google users, Resend mode).
#
# Keyed by `slug`, the same entity key config/workspace_icons.yml and
# credential_records.entity use ("turf-monster"), so a client's credential
# records and its badge join by name. The Google workspace joins by `domain`.
#
# `hosting` holds only OVERRIDES of each software's default hosting mode
# (config/workspace_icons.yml `hosting: ms`): { "heroku" => "own" } for a
# white-label client. `extra_software` adds software its tier and its records do
# not already imply.
class CreateStackClients < ActiveRecord::Migration[8.1]
  def change
    create_table :stack_clients do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :tier, null: false
      t.string :domain
      t.integer :google_users
      t.string :resend_mode
      t.jsonb :hosting, null: false, default: {}
      t.jsonb :extra_software, null: false, default: []
      t.integer :position, null: false, default: 0
      t.text :notes
      t.timestamps
    end
    add_index :stack_clients, :slug, unique: true
    add_index :stack_clients, :domain
  end
end

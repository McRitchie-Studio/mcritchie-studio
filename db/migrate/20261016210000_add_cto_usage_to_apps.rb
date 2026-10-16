# The CTO usage tier of an app (docs/agents/system/agent-usage.md; plan: Phase 7
# of .agents/epics/domain-agents.md). `package_tier` is a key of
# config/workspace_packages.yml (vibe, builder, pro, team, enterprise), whose
# `cto_monthly_tokens` is the app's monthly CTO allowance; nil means no tier,
# and no tier means no cap. Not `tier`: config/apps.yml already uses that word
# for studio | product | basic.
#
# `cto_cap_lifted_at` is an admin's per-app lift: while set, the app is never
# capped whatever its usage (`cto_cap_lifted_by` says who).
#
# The data step copies each client's tier from stack_clients (the only place
# a client's package is recorded today) onto the app with the same slug, so the
# release phase sets production up. "internal" (our own stacks) is not a
# package and stays nil. Bare SQL, so this migration still runs after the
# models change.
class AddCtoUsageToApps < ActiveRecord::Migration[8.1]
  def up
    add_column :apps, :package_tier, :string
    add_column :apps, :cto_cap_lifted_at, :datetime
    add_column :apps, :cto_cap_lifted_by, :string
    add_index :agent_messages, [ :soul_slug, :completed_at ], name: "index_agent_messages_on_soul_and_completed_at"

    execute <<~SQL.squish
      UPDATE apps SET package_tier = stack_clients.tier
      FROM stack_clients
      WHERE stack_clients.slug = apps.slug AND stack_clients.tier <> 'internal'
    SQL
  end

  def down
    remove_index :agent_messages, name: "index_agent_messages_on_soul_and_completed_at"
    remove_column :apps, :cto_cap_lifted_by
    remove_column :apps, :cto_cap_lifted_at
    remove_column :apps, :package_tier
  end
end

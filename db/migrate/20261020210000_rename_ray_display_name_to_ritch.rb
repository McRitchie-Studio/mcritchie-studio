# The orchestrator soul's display name becomes Ritch (Alex, 2026-10-20: "I want
# to change 'Ray' to 'Ritch'"). Only the Agent row's `name` moves; the slug `ray`
# and every slug-keyed row stay (the slug rename is a later step). The seed
# (config/souls.yml) says Ritch too, but the release phase runs only db:migrate,
# so the deployed row is renamed here. A row someone renamed by hand to anything
# but Ray is left alone.
class RenameRayDisplayNameToRitch < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE agents SET name = 'Ritch', updated_at = NOW() WHERE slug = 'ray' AND name = 'Ray'"
  end

  def down
    execute "UPDATE agents SET name = 'Ray', updated_at = NOW() WHERE slug = 'ray' AND name = 'Ritch'"
  end
end

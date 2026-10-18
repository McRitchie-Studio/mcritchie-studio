# The orchestrator soul's display name becomes Ray (Alex, 2026-10-18: "That's my
# middle name and it reads better than Xan"). Only the Agent row's `name` moves;
# the slug `xan` and every slug-keyed row stay (the slug rename is a later step,
# `ray-slug-rename`). The seed (config/souls.yml) says Ray too, but the release
# phase runs only db:migrate, so the deployed row is renamed here. A row someone
# renamed by hand to anything but Xan is left alone.
class RenameXanDisplayNameToRay < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE agents SET name = 'Ray', updated_at = NOW() WHERE slug = 'xan' AND name = 'Xan'"
  end

  def down
    execute "UPDATE agents SET name = 'Xan', updated_at = NOW() WHERE slug = 'xan' AND name = 'Ray'"
  end
end

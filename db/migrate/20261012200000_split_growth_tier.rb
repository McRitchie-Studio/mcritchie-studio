# The 2026-10-12 ladder (task cto-and-team-tiers): Vibe, Builder, Pro, Team.
# Growth ($500/mo) split into Pro ($500/mo, Growth's platform features, "your
# fractional CTO") and Team ($1,500/mo, Pro plus the marketing rows), and the
# old $100 Pro was renamed Builder. `growth` leaves config/workspace_packages.yml
# in the same deploy, and `pro` now names a DIFFERENT tier, so every stored row
# must move, or the models that validate against WorkspacePackage.keys
# (StackClient, AppRequest) would hold rows that can no longer be saved or that
# silently mean the wrong tier.
#
# ORDER MATTERS. `pro` moves to `builder` FIRST, before any growth row becomes
# `pro`; the other way round, a client just moved onto the new Pro would be
# swept on to Builder. Postgres runs the whole migration in one transaction, so
# no reader sees a half-moved table.
#
# Where each growth row goes, as Mr. McRitchie decided: Commercial Welding takes
# Pro (it runs the workspace and platform, no marketing), Turf Monster takes
# Team. Every other growth row takes Team, the tier that keeps everything Growth
# promised. Production on 2026-10-12 (a read-only count): stack_clients growth×2
# (those two), pro×1 (Cyvasse → builder), vibe×1, internal×2; app_requests vibe×7.
#
# `vibe`, `internal` and `enterprise` rows are untouched. The mapping is written
# out here, not read from the model, so it means the same thing whatever the
# config later becomes.
class SplitGrowthTier < ActiveRecord::Migration[8.1]
  RETIRED = "growth"
  RENAMED = { "pro" => "builder" }.freeze
  DEFAULT = "team"
  # stack_clients.slug => the tier that client takes instead of DEFAULT.
  CLIENT_TIERS = { "commercial-welding" => "pro", "turf-monster" => "team" }.freeze
  TABLES = %w[stack_clients app_requests].freeze

  def up
    # 1. The old $100 Pro becomes Builder, while no row yet holds the new Pro.
    RENAMED.each { |from, to| TABLES.each { |table| move(table, from: from, to: to) } }
    # 2. Growth splits.
    CLIENT_TIERS.each do |slug, tier|
      execute "UPDATE stack_clients SET tier = #{quote(tier)} WHERE tier = #{quote(RETIRED)} AND slug = #{quote(slug)}"
    end
    TABLES.each { |table| move(table, from: RETIRED, to: DEFAULT) }
  end

  # The reverse, also in a safe order: the new Pro and Team fold back into
  # growth FIRST, and only then does Builder take back the `pro` key. A pro or
  # team row written after the deploy also returns as growth, the only tier
  # that existed for it before.
  def down
    TABLES.each do |table|
      execute "UPDATE #{table} SET tier = #{quote(RETIRED)} WHERE tier IN (#{quote('pro')}, #{quote('team')})"
    end
    RENAMED.each { |from, to| TABLES.each { |table| move(table, from: to, to: from) } }
  end

  private

  def move(table, from:, to:)
    execute "UPDATE #{table} SET tier = #{quote(to)} WHERE tier = #{quote(from)}"
  end

  def quote(value) = connection.quote(value)
end

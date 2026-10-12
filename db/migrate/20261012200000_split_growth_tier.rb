# The 2026-10-12 ladder (task cto-and-team-tiers): Growth ($500/mo) split into
# CTO ($500/mo, Growth's platform features) and Team ($1,500/mo, CTO plus the
# marketing rows). `growth` leaves config/workspace_packages.yml in the same
# deploy, so every stored `growth` row must move, or the models that validate
# against WorkspacePackage.keys (StackClient, AppRequest) would hold rows that
# can no longer be saved.
#
# Where each row goes, as Mr. McRitchie decided: Commercial Welding takes CTO
# (it runs the workspace and platform, no marketing), Turf Monster takes Team.
# Every other growth row takes Team, the tier that keeps everything Growth
# promised (marketing included), so no client loses a feature in the move.
# App requests never carried growth from /build (it writes the vibe default),
# so any there are hand-set rows and follow the same rule.
#
# `internal` and `enterprise` rows are untouched. The mapping is written out
# here, not read from the model, so it means the same thing whatever the
# config later becomes.
class SplitGrowthTier < ActiveRecord::Migration[8.1]
  RETIRED = "growth"
  DEFAULT = "team"
  # stack_clients.slug => the tier that client takes instead of DEFAULT.
  CLIENT_TIERS = { "commercial-welding" => "cto", "turf-monster" => "team" }.freeze
  TABLES = %w[stack_clients app_requests].freeze

  def up
    CLIENT_TIERS.each do |slug, tier|
      execute "UPDATE stack_clients SET tier = #{quote(tier)} WHERE tier = #{quote(RETIRED)} AND slug = #{quote(slug)}"
    end
    TABLES.each do |table|
      execute "UPDATE #{table} SET tier = #{quote(DEFAULT)} WHERE tier = #{quote(RETIRED)}"
    end
  end

  # Both new keys came from growth, so down folds them back into it. A cto or
  # team row written after the deploy also returns as growth: the only tier
  # that existed for it before.
  def down
    TABLES.each do |table|
      execute "UPDATE #{table} SET tier = #{quote(RETIRED)} WHERE tier IN (#{quote('cto')}, #{quote('team')})"
    end
  end

  private

  def quote(value) = connection.quote(value)
end

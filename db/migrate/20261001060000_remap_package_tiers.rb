# Pricing tiers v2 (approved 2026-09-30): Launch, Host, Workspace and Agentic
# became Vibe, Pro, Growth and Enterprise. Every stored tier moves to its new
# key in the same deploy that changes config/workspace_packages.yml, or the
# models that validate against WorkspacePackage.keys (StackClient, AppRequest)
# would hold rows that can no longer be saved. `internal` is untouched.
#
# The mapping is written out here, not read from WorkspacePackage::LEGACY_TIERS,
# so the migration means the same thing whatever the model later becomes. The
# migration's test holds the two to each other.
class RemapPackageTiers < ActiveRecord::Migration[8.1]
  MAP = { "launch" => "vibe", "host" => "pro", "workspace" => "growth", "agentic" => "growth" }.freeze
  # Down is lossy where two keys merged (workspace and agentic both became
  # growth): growth goes back to agentic, the tier both Growth comps sat on or
  # above. Enterprise had no predecessor and also returns as agentic.
  REVERSE = { "vibe" => "launch", "pro" => "host", "growth" => "agentic", "enterprise" => "agentic" }.freeze
  TABLES = %w[stack_clients app_requests].freeze

  def up
    remap(MAP)
    change_column_default :app_requests, :tier, from: "launch", to: "vibe"
  end

  def down
    change_column_default :app_requests, :tier, from: "vibe", to: "launch"
    remap(REVERSE)
  end

  private

  def remap(mapping)
    TABLES.each do |table|
      mapping.each do |from, to|
        execute "UPDATE #{table} SET tier = #{connection.quote(to)} WHERE tier = #{connection.quote(from)}"
      end
    end
  end
end

# The Rails-side reader for config/workspace_icons.yml — the same file
# bin/workspace-icon renders from (through bin/lib/workspace_icon.rb, which runs
# without Rails), so the page and the CLI can never disagree about a scope.
module WorkspaceIconConfig
  CONFIG = Rails.root.join("config/workspace_icons.yml")

  module_function

  def workspaces = YAML.safe_load_file(CONFIG).fetch("workspaces", {})

  # The rendered icon for one software x workspace, as an image_tag path, or
  # nil when bin/workspace-icon has not rendered that pair yet.
  def asset(software, scope)
    path = "workspace_icons/#{software}/#{scope}.png"
    Rails.root.join("app/assets/images", path).file? ? path : nil
  end

  # entity => Google Workspace domain, for the entities that have one.
  def domains = workspaces.filter_map { |scope, ws| [ scope, ws["domain"] ] if ws["domain"].present? }.to_h
end

# The Rails-side reader for config/onepass_icons.yml — the same file
# bin/onepass-icon renders from (through bin/lib/onepass_icon.rb, which runs
# without Rails), so the page and the CLI can never disagree about a scope.
module OnepassIconConfig
  CONFIG = Rails.root.join("config/onepass_icons.yml")

  module_function

  def workspaces = YAML.safe_load_file(CONFIG).fetch("workspaces", {})

  # entity => Google Workspace domain, for the entities that have one.
  def domains = workspaces.filter_map { |scope, ws| [ scope, ws["domain"] ] if ws["domain"].present? }.to_h
end

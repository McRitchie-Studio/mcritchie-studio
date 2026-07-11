# frozen_string_literal: true

# BinHelpers — tiny cross-script utilities the devops CLIs (bin/conductor,
# bin/pr-review, bin/devops-cycle) used to carry identical copies of.
#
# Only EXACT-match duplicates live here. compact_list/bullet_list/truthy? stay
# per-script: pr-review and devops-cycle disagree on whitespace-only items, and
# qa-intake and agent-marker disagree on what counts as truthy.
module BinHelpers
  # The bin/ directory these scripts (and this lib) ship in.
  BIN_DIR = File.expand_path("..", __dir__)

  module_function

  # Resolve a helper binary: an explicit env override (for tests) wins, else the
  # sibling script next to the caller (the real tool in production).
  def bin_for(env_key, default_name)
    override = ENV[env_key].to_s.strip
    return override unless override.empty?

    File.join(BIN_DIR, default_name)
  end

  # Collapse a value to a filesystem-safe slug (scout/review artifact names).
  def safe_filename(value)
    value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A-+|-+\z/, "")
  end
end

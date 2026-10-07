# frozen_string_literal: true

# THE ONE KEY MAP for the devops list fields: which `bin/task` flag writes which
# devops key, and which of those keys hold IDENTIFIERS rather than prose. bin/task
# (no Rails) requires this file; Task reads it through autoload. Both sides derive
# their rule from it, so the CLI's comma split and the server's comma split
# cannot name different keys.
#
# Identifier keys (repositories, risk_tags) hold values no legal entry spells with
# a comma, so a comma there is a joined list: bin/task splits `--repo a,b` into two
# entries (guard catalog row 3.6), and Task.normalize_devops_metadata splits a joined
# entry that arrives through the raw API. Release::Conductor resolves each repository and
# ReviewerSelector matches each risk tag exactly, so a joined entry names a phantom
# repo or a tag no gate matches.
#
# Prose keys (acceptance, test_plan, checks_run) carry ordinary punctuation: a
# comma there is part of one entry and is never split or refused.
module DevopsListFlags
  # Repeatable `bin/task` flag => the devops list key it appends to.
  FLAGS = {
    "--repo" => "repositories",
    "--risk" => "risk_tags",
    "--accept" => "acceptance",
    "--test" => "test_plan",
    "--checks" => "checks_run"
  }.freeze

  # The keys whose entries are identifiers. Every one is a key some flag writes.
  IDENTIFIER_KEYS = %w[repositories risk_tags].freeze

  # The flags whose value bin/task splits on commas: exactly the flags that write an
  # identifier key.
  COMMA_FREE_FLAGS = FLAGS.select { |_flag, key| IDENTIFIER_KEYS.include?(key) }.keys.freeze
end

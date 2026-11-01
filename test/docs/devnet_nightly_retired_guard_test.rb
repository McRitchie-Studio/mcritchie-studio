# frozen_string_literal: true

require "test_helper"

# turf-monster's scheduled devnet workflow never once executed and was deleted on
# 2026-10-24 (task turf-devnet-config-truth). The devnet signal is the per-release
# `contest-rehearsal` gauntlet that `qa-release` records on the release. A live doc,
# comment or test that still names the workflow tells the next reader a lane exists
# that does not, so its name resolves only in docs/agents/archive/ and git history.
class DevnetNightlyRetiredGuardTest < ActiveSupport::TestCase
  ROOTS = %w[docs app lib bin .github config db test].freeze
  ARCHIVE = Rails.root.join("docs/agents/archive").to_s
  SELF = File.expand_path(__FILE__)
  RETIRED = /devnet[\s_-]nightly|DEVNET_NIGHTLY_ENABLED/i
  # The task that removed the name is named for it; its slug is not the workflow.
  TASK_SLUG = "devnet-nightly-reference-sweep"

  def scanned_files
    ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, "**", "*"), File::FNM_DOTMATCH) }
         .select { |p| File.file?(p) }
         .reject { |p| p.start_with?("#{ARCHIVE}/") || File.expand_path(p) == SELF }
  end

  def hits(path, text)
    text.each_line.with_index(1).filter_map do |line, n|
      "#{Pathname.new(path).relative_path_from(Rails.root)}:#{n}" if retired?(line)
    end
  end

  def retired?(line)
    line.gsub(TASK_SLUG, "").match?(RETIRED)
  end

  test "[unit] the deleted devnet nightly workflow is named only in the archive" do
    files = scanned_files
    assert_operator files.size, :>=, 1_000, "the scan read too few files to be the real tree"

    found = files.flat_map do |path|
      text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      hits(path, text)
    end
    assert_empty found,
                 "these lines name turf-monster's deleted devnet nightly workflow as if it ran. The devnet " \
                 "signal is the per-release contest-rehearsal recorded by qa-release; leave history to git"
  end

  test "[unit] the scan bites every spelling and spares the task slug" do
    ["the Devnet Nightly workflow", "devnet-nightly.yml", "vars.DEVNET_NIGHTLY_ENABLED", "devnet_nightly job"].each do |probe|
      assert retired?(probe), "the scan missed #{probe.inspect}"
    end
    refute retired?("task #{TASK_SLUG} swept the references")
    refute retired?("the per-release contest-rehearsal on devnet")
  end
end

# frozen_string_literal: true

require "test_helper"

# The shared Discord bot (user 1481150857809760399, 1Password `agents.discord.xan`)
# was renamed Alex on 2026-10-27 (task discord-bot-becomes-alex, on Alex McRitchie's
# ruling of 2026-10-26). A live doc, comment or test step that still says to post
# `@Ritch`, or that the bot is "still Ritch", sends the next operator to mention a
# name nobody in the guild carries, so the old name resolves only in the archive.
class DiscordBotNamedAlexGuardTest < ActiveSupport::TestCase
  ROOTS = %w[docs app lib bin .github config db test].freeze
  ARCHIVE = Rails.root.join("docs/agents/archive").to_s
  SELF = File.expand_path(__FILE__)
  STALE = /@Ritch\b|still\s+"?Ritch\b/i

  def scanned_files
    ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, "**", "*"), File::FNM_DOTMATCH) }
         .select { |p| File.file?(p) }
         .reject { |p| p.start_with?("#{ARCHIVE}/") || File.expand_path(p) == SELF }
  end

  def stale?(line)
    line.match?(STALE)
  end

  test "[unit] no live doc or config names the Discord bot @Ritch" do
    files = scanned_files
    assert_operator files.size, :>=, 1_000, "the scan read too few files to be the real tree"

    found = files.flat_map do |path|
      text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      text.each_line.with_index(1).filter_map do |line, n|
        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{n}" if stale?(line)
      end
    end
    assert_empty found,
                 "these lines still call the shared Discord bot Ritch; it is named Alex in Discord " \
                 "(username, guild role and application). Move history to docs/agents/archive/"
  end

  test "[unit] the scan bites every stale spelling and spares the current ones" do
    ["Post `@Ritch what is building?`", "@ritch one", 'its Discord name is still "Ritch"',
     "Its Discord name is still Ritch:"].each do |probe|
      assert stale?(probe), "the scan missed #{probe.inspect}"
    end
    ["Post `@Alex what is building?`", "Alex McRitchie", "mcritchie-studio", "@McRitchie"].each do |probe|
      refute stale?(probe), "the scan wrongly flagged #{probe.inspect}"
    end
  end
end

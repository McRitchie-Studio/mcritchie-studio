require "test_helper"

# [unit] Task hub-theme-and-integrations-cleanup. studio-engine 0.130.0 owns the theme
# flip (one view-transition crossfade under data-theme-flip, set by $store.theme.set())
# and renamed the rotating ring .studio-team-glow to .edge-rotate-glow, keeping the old
# name as a deprecated alias. The hub carries neither leftover: no 300ms theme-transition
# utility of its own, and no caller of the old ring name or its knobs. The engine's alias
# stays; this guard reads only the hub's own sources.
class ThemeLeftoversTest < ActiveSupport::TestCase
  SOURCES = %w[app e2e config lib].freeze
  SKIP = %r{\Aapp/assets/builds/}

  def hub_files
    Dir.chdir(Rails.root) do
      `git ls-files -- #{SOURCES.join(' ')}`.split("\n").reject { _1.match?(SKIP) }
    end
  end

  def hits(pattern)
    hub_files.select do |path|
      text = File.read(Rails.root.join(path), mode: "rb")
      text.include?(pattern)
    rescue Errno::ENOENT
      false
    end
  end

  test "the hub defines and uses no theme-transition class: the engine's crossfade replaced it" do
    files = hub_files
    assert files.any? { _1 == "app/assets/tailwind/application.css" }, "the guard reads the hub's stylesheet"
    assert_empty hits("theme-transition")
  end

  test "hub callers use .edge-rotate-glow and its knobs, not the deprecated .studio-team-glow alias" do
    assert_empty hits("studio-team-glow")
    assert_not_empty hits("edge-rotate-glow"), "the board's review ring and the meter glow wear the new name"
  end
end

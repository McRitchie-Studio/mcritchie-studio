# frozen_string_literal: true

require "test_helper"

# [unit] Every chip in the hub's markup that puts a role's ink on that role's
# tint (`bg-success/20 text-success-ink`) clears WCAG AA, 4.5:1, in both themes.
#
# Since studio-engine 0.103.0 the theme resolver derives each ink against its
# role's tint at every strength in Studio::ThemeResolver::TINT_ALPHAS (10%, 15%,
# 20%, as Chromium paints them). A chip on a stronger tint is outside that
# search, and its ink can fall below AA: the board's live crew ticker sat on
# `bg-success/30` and read as low as 4.01:1 on a painted tint.
#
# So this reads the markup, finds each class string that pairs `bg-<role>/<n>`
# with `text-<role>-ink`, and grades that pair with the hub's own resolved
# colours: the ink against the tint over each of the four surfaces, and one unit
# either side of each tint, the rounding a browser paints. e2e/contrast.js holds
# the same 4.5 floor on the painted pixels (CHIP_ON_TINT).
#
# CONTROL: put the live ticker in components/_stage_agent_avatars.html.erb back
# on `bg-success/30` and both tests fail, naming that file.
class ChipTintContrastTest < ActiveSupport::TestCase
  AA = 4.5
  ROLES = %w[success warning danger primary].freeze
  SOURCES = %w[app/views/**/*.erb app/components/**/*.{rb,erb} app/helpers/**/*.rb].freeze
  TINT = %r{\bbg-(#{ROLES.join('|')})/(\d+)\b}

  # [path, role, percent] for every tint whose quoted class string carries the
  # same role's ink.
  def chips
    @chips ||= SOURCES.flat_map { |glob| Dir[Rails.root.join(glob)] }.sort.flat_map do |path|
      text = File.read(path)
      text.to_enum(:scan, TINT).map do
        match = Regexp.last_match
        role, percent = match[1], match[2].to_i
        opening = text.rindex(/["']/, match.begin(0)) || 0
        closing = text.index(/["']/, match.end(0)) || text.length
        next unless text[opening..closing].include?("text-#{role}-ink")

        [Pathname(path).relative_path_from(Rails.root).to_s, role, percent]
      end.compact
    end.uniq
  end

  # The hub's configured colours, read the way the engine's theme tag reads them
  # when no ThemeSetting row overrides them.
  def colors = Studio.theme_config.to_h.symbolize_keys

  # The lowest ratio of `role`'s ink on its `alpha` tint, over both themes'
  # surfaces and the painted neighbours of each tint.
  def worst(role, alpha)
    res = Studio::ThemeResolver.new(colors)
    themes = {
      dark: [res.dark_mode_vars.merge(res.primary_palette_vars), res.dark_surfaces(colors[:dark] || "#1A1535")],
      light: [res.light_mode_vars.merge(res.primary_palette_vars), res.light_surfaces(colors[:light] || "#f8fafc")]
    }
    themes.map do |_theme, (vars, surfaces)|
      ink = vars.fetch("--color-#{role}-ink")
      surfaces.flat_map do |surface|
        tint = Studio::ColorScale.blend(vars.fetch("--color-#{role}"), surface, alpha)
        rgb = Studio::ColorScale.hex_to_rgb(tint)
        [tint, *[1, -1].map { |d| Studio::ColorScale.rgb_to_hex(*rgb.map { |c| (c + d).clamp(0, 255) }) }]
      end.map { |bg| Studio::ColorScale.contrast_ratio(ink, bg) }.min
    end.min
  end

  test "the scan finds the hub's tinted chips" do
    found = chips.map { |_path, role, percent| "#{role}/#{percent}" }.uniq
    assert_includes found, "success/10", "the scan no longer sees the ordinary status chip"
    assert_includes found, "success/20", "the scan no longer sees the workflow chips"
  end

  test "every ink-on-tint chip sits on a tint the engine derives its ink against" do
    derived = Studio::ThemeResolver::TINT_ALPHAS.map { |alpha| (alpha * 100).round }.uniq
    outside = chips.reject { |_path, _role, percent| derived.include?(percent) }

    assert_empty outside.map { |path, role, percent| "#{path}: bg-#{role}/#{percent}" },
                 "these tints are stronger than any the engine derives an ink for (#{derived.join(', ')}%)"
  end

  test "every ink-on-tint chip clears AA on its tint in both themes" do
    below = chips.filter_map do |path, role, percent|
      ratio = worst(role, percent / 100.0)
      "#{path}: text-#{role}-ink on bg-#{role}/#{percent} is #{ratio.round(2)}:1" if ratio < AA
    end

    assert_empty below
  end
end

require "test_helper"

# Hub views and helpers draw status colour from engine tokens (status_tone and
# the -ink / fill / border role utilities), never from a fixed Tailwind
# palette or a dark: twin, and use the preset type scale instead of arbitrary
# 10px and 11px sizes. docs: studio-engine docs/FRONT_END_STANDARD.md, Styling.
class StatusColourTokensTest < ActiveSupport::TestCase
  ROOTS = %w[app/views app/helpers].freeze

  PALETTE = /\b(?:bg|text|border|ring|from|to|via|fill|stroke|divide|outline|shadow|accent|decoration)-(?:red|amber|yellow|green|emerald|blue|cyan|sky|orange|rose|pink|purple|indigo|teal|lime|fuchsia|gray|slate|zinc|neutral|stone|violet|mint|navy)(?:-\d{2,3})?\b/

  # Data colours, not status colours: an ordinal grade scale, sports category
  # palettes and a logo tile on a fixed white ground. Each keeps its own hues
  # on purpose; collapsing them onto five status roles would erase the
  # distinctions they exist to draw.
  DATA_PALETTE_FILES = %w[
    app/helpers/grade_helper.rb
    app/helpers/rankings_helper.rb
    app/views/contracts/index.html.erb
    app/views/packages/_brand.html.erb
    app/views/rankings/coaches.html.erb
    app/views/rankings/pass_first.html.erb
    app/views/team_grades/show.html.erb
  ].freeze

  # The app ladder's lane palette: measured hex pairs (see the comment above
  # APP_LADDER_LANE_TONES), a categorical chart palette with no token yet.
  DARK_HEX_PALETTE_FILES = %w[app/helpers/application_helper.rb].freeze

  COMMENT_LINE = %r{\A\s*(?:#|//|<%#|\*)}

  # The CI and release meters lay their text over a tinted fill, and their
  # palette pairs were measured for AA there by e2e/ci_meter_fit.spec.js and
  # e2e/release_meter_fit.spec.js. The engine inks are derived against plain
  # surfaces and fail over that fill (3.85:1 and 4.25:1 measured in CI), so
  # these lines keep their measured pairs until the engine derives an ink
  # against a tint. Each carries this marker; the count is pinned below.
  METER_MARKER = "# measured meter tone"
  METER_LINES = 9

  def source_files
    ROOTS.flat_map { |root| Dir[Rails.root.join(root, "**/*.{erb,rb}")] }
         .map { |path| path.delete_prefix("#{Rails.root}/") }
  end

  def offending_lines(pattern, skip_files: [])
    source_files.reject { |path| skip_files.include?(path) }.flat_map do |path|
      in_erb_comment = false
      File.readlines(Rails.root.join(path)).each_with_index.filter_map do |line, index|
        comment = in_erb_comment || line.match?(COMMENT_LINE)
        in_erb_comment = (in_erb_comment || line.include?("<%#")) && !line.include?("%>")
        meter = line.include?(METER_MARKER)
        "#{path}:#{index + 1}: #{line.strip}" if !comment && !meter && line.match?(pattern)
      end
    end
  end

  test "[component] no hub view or helper draws a status colour from a fixed palette" do
    offenders = offending_lines(PALETTE, skip_files: DATA_PALETTE_FILES)
    assert_empty offenders, "use status_tone or the engine role tokens:\n#{offenders.join("\n")}"
  end

  test "[component] the meter exemption covers exactly the measured meter lines" do
    marked = source_files.sum { |path| File.read(Rails.root.join(path)).scan(METER_MARKER).size }
    assert_equal METER_LINES, marked, "a new meter-tone marker needs its own measurement; a removed one lowers METER_LINES"
  end

  test "[component] the data-palette exemption still names files that carry a palette" do
    DATA_PALETTE_FILES.each do |path|
      assert_match PALETTE, Rails.root.join(path).read, "#{path} no longer needs its exemption; drop it"
    end
  end

  test "[component] no hub view or helper pairs a colour with a dark: twin" do
    offenders = offending_lines(/\bdark:(?:hover:)?(?:bg|text|border)-(?!\[#)/)
    hex_twins = offending_lines(/\bdark:(?:bg|text|border)-\[#/, skip_files: DARK_HEX_PALETTE_FILES)
    assert_empty offenders + hex_twins, "a token serves both themes:\n#{(offenders + hex_twins).join("\n")}"
  end

  test "[component] arbitrary 10px and 11px sizes use the preset text-3xs and text-2xs" do
    offenders = offending_lines(/\btext-\[1[01]px\]/)
    assert_empty offenders, "use text-3xs (10px) or text-2xs (11px):\n#{offenders.join("\n")}"
  end

  # The swap is size-for-size: the engine preset defines both as bare sizes, so
  # text-3xs renders exactly what text-[10px] did.
  test "[component] the engine preset defines text-3xs as 10px and text-2xs as 11px" do
    preset = Studio::Engine.root.join("tailwind/studio.tailwind.config.js").read
    assert_match(/'2xs':\s*'0\.6875rem'/, preset)
    assert_match(/'3xs':\s*'0\.625rem'/, preset)
  end
end

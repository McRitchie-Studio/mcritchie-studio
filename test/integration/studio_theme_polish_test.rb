require "test_helper"

# Component-tier guards for ui-only Studio theme polish. These request renders
# exercise the ERB components through the normal layout without adding browser
# behavior or persistence coverage.
class StudioThemePolishTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  test "[component] stages guide renders tokenized light and dark stage badges" do
    get stages_path
    assert_response :success

    assert_select "[data-test='stage-workflow']", count: 2
    assert_select "[data-test='stage-guide-card'].rounded-lg.bg-surface", minimum: 1

    # Stage badges come from status_tone: engine tokens that serve both themes.
    assert_includes response.body, "bg-primary/10 text-heading border border-primary/40"
    assert_includes response.body, "bg-warning/10 text-warning-ink border border-warning/40"
    refute_includes response.body, "bg-blue-900/50 text-blue-300",
      "task stage badges should not render as dark-only blue pills"
    refute_match(/dark:(bg|text|border)-(blue|primary)-/, response.body,
      "a token badge needs no dark: twin")
  end

  test "[component] layout nav and link sidebar use tokenized interactive states" do
    get links_path
    assert_response :success

    # The header is the engine's navbar; its surface and the mark's theme pair
    # are this app's CSS on it (the .nav-shell block in application.css).
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_match(/\.nav-shell\[data-pin="nav"\]\s*\{[^}]*@apply bg-page\/95 supports-\[backdrop-filter\]:backdrop-blur/m, css,
                 "the pinned header is the page colour at 95%, blurred where supported")
    # THE INVERT PAIR is the theme concern here: the mark is drawn in white, so
    # it inverts for the light theme and un-inverts in dark mode.
    assert_match(/^\s*\.nav-shell \.nav-logo\s*\{[^}]*filter:\s*invert\(1\)/m, css, "the mark inverts for the light theme")
    assert_match(/^\s*\.dark \.nav-shell \.nav-logo\s*\{[^}]*filter:\s*none/m, css, "and un-inverts in dark mode")
    assert_select "header.nav-shell img.nav-logo", 1
    assert_includes response.body, "hover:bg-surface-alt"
    assert_includes response.body, "focus-visible:ring-primary/40"
    assert_includes response.body, "inline-flex h-9 w-9 items-center justify-center"
  end
end

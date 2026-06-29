require "test_helper"

# Component-tier guards for ui-only Studio theme polish. These request renders
# exercise the ERB components through the normal layout without adding browser
# behavior or persistence coverage.
class StudioThemePolishTest < ActionDispatch::IntegrationTest
  test "[component] stages guide renders tokenized light and dark stage badges" do
    get stages_path
    assert_response :success

    assert_select "[data-test='stage-workflow']", count: 2
    assert_select "[data-test='stage-guide-card'].rounded-lg.bg-surface", minimum: 1

    assert_includes response.body, "bg-blue-100 text-blue-800"
    assert_includes response.body, "dark:bg-blue-900/50 dark:text-blue-200"
    assert_includes response.body, "bg-primary-100 text-primary-900"
    assert_includes response.body, "dark:bg-primary-900/50 dark:text-primary-200"
    refute_includes response.body, "bg-blue-900/50 text-blue-300",
      "task stage badges should not render as dark-only blue pills"
  end

  test "[component] layout nav and link sidebar use tokenized interactive states" do
    get links_path
    assert_response :success

    assert_includes response.body, "bg-page/95"
    assert_includes response.body, "supports-[backdrop-filter]:backdrop-blur"
    assert_includes response.body, "invert transition-all duration-300 dark:invert-0"
    assert_includes response.body, "hover:bg-surface-alt"
    assert_includes response.body, "focus-visible:ring-primary/40"
    assert_includes response.body, "inline-flex h-9 w-9 items-center justify-center"
  end
end

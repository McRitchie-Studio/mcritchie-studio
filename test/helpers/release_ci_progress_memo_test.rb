require "test_helper"

# ApplicationHelper#release_ci_progress is memoised PER RELEASE for the render.
#
# /deployments draws two release cards — the current release and the last shipped
# one — and each walks its member repos resolving a SHA and folding check jobs.
# Un-memoised, that ran once per card: 18 ci_check_jobs reads plus 18
# github_workflow_runs reads per production request, every one a duplicate.
#
# Keyed by release, not a single slot, because the two cards are DIFFERENT
# releases — one memo slot would serve the current release's CI to the shipped
# card, which is a wrong-data bug, not a slow one. That is what the second test
# here pins.
class ReleaseCiProgressMemoTest < ActionView::TestCase
  include ApplicationHelper

  class CountingReader
    attr_reader :calls

    def initialize = @calls = []

    def for_release(release)
      @calls << release
      { "mcritchie-studio" => "progress-for-#{release&.slug}" }
    end
  end

  setup do
    @reader = CountingReader.new
    @ci_progress_reader = @reader
    @current = Release.create!(branch: "release/memo-current", state: "assembling")
    @shipped = Release.create!(branch: "release/memo-shipped", state: "shipped")
  end

  test "[unit] the same release is resolved once per render" do
    first = release_ci_progress(@current)
    second = release_ci_progress(@current)

    assert_equal first, second
    assert_equal 1, @reader.calls.size, "a second card asking for the same release must not re-read"
  end

  test "[unit] a different release still gets its OWN progress" do
    current = release_ci_progress(@current)
    shipped = release_ci_progress(@shipped)

    assert_equal 2, @reader.calls.size
    assert_equal [@current, @shipped], @reader.calls
    # The memo must not hand the second card the first card's answer.
    assert_equal "progress-for-#{@current.slug}", current["mcritchie-studio"]
    assert_equal "progress-for-#{@shipped.slug}", shipped["mcritchie-studio"]
    refute_equal current, shipped
  end

  test "[unit] a blank release memoises without blowing up" do
    assert_equal release_ci_progress(nil), release_ci_progress(nil)
    assert_equal 1, @reader.calls.size
  end
end

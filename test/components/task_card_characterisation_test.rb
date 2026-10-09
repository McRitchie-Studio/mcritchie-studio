# frozen_string_literal: true

require "test_helper"
require_relative "../support/task_card_scenarios"
require_relative "../support/task_card_rendering"

# [component] The card's DOM in every state it branches on, compared with a
# committed snapshot per state (test/fixtures/files/task_card/<state>.html).
# Whitespace between tags is normalised; nothing else is.
#
# A deliberate markup change regenerates them, and the diff is the review:
#   UPDATE_TASK_CARD_SNAPSHOTS=1 bin/rails test test/components/task_card_characterisation_test.rb
class TaskCardCharacterisationTest < ActionView::TestCase
  include TaskCardScenarios
  include TaskCardRendering

  SNAPSHOT_DIR = Rails.root.join("test/fixtures/files/task_card")

  setup do
    travel_to TaskCardScenarios::NOW
    %w[Carl Avi Steffon Pokemon].each_with_index do |name, position|
      Agent.create!(name: name, slug: name.downcase, position: position)
    end
    @agents = Agent.order(:position).to_a
  end

  TaskCardScenarios::NAMES.each do |name|
    test "the #{name} card renders its snapshot" do
      scenario = task_card_scenario(name)
      actual = normalise(card_html(scenario))
      path = SNAPSHOT_DIR.join("#{name}.html")

      if ENV["UPDATE_TASK_CARD_SNAPSHOTS"]
        FileUtils.mkdir_p(SNAPSHOT_DIR)
        path.write(actual)
      end

      assert path.exist?, "no snapshot for #{name}; run with UPDATE_TASK_CARD_SNAPSHOTS=1"
      assert_equal path.read, actual, "the #{name} card's DOM moved"
    end
  end

  test "every snapshot on disk belongs to a scenario" do
    on_disk = SNAPSHOT_DIR.glob("*.html").map { |path| path.basename(".html").to_s }.sort
    assert_equal TaskCardScenarios::NAMES.sort, on_disk
  end

  private

  def card_html(scenario)
    render_task_card(scenario.fetch(:task).reload, crew_board: scenario.fetch(:crew_board), **scenario.fetch(:given))
  end

  # One tag per line, runs of whitespace collapsed, asset digests dropped.
  def normalise(html)
    html.gsub(/<!--.*?-->/m, "")
        .gsub(/\s+/, " ")
        .gsub(/-[0-9a-f]{8,64}(\.(?:png|jpg|jpeg|svg|webp|gif))/, '\1')
        .gsub(/>\s*</, ">\n<")
        .strip + "\n"
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] The prompt follows the text mode and the brand kit.
class EmailImages::PromptTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup { EmailImageBrief.delete_all }

  test "baked asks for the headline spelled exactly" do
    prompt = EmailImages::Prompt.call(turf_brief(text_mode: "baked"))

    assert_includes prompt, %("You're In!")
    assert_includes prompt, "spelled exactly"
    assert_includes prompt, "mascot"
    assert_includes prompt, "#2E7D32"
    assert_includes prompt, "No real people"
  end

  test "none forbids any lettering" do
    prompt = EmailImages::Prompt.call(turf_brief(text_mode: "none"))

    assert_includes prompt, "NO text"
    assert_not_includes prompt, "You're In!"
  end

  test "notes ride along" do
    prompt = EmailImages::Prompt.call(turf_brief(prompt_notes: "the gator holds a golden ticket"))
    assert_includes prompt, "golden ticket"
  end

  test "a round with no notes still records its number; none means no round line" do
    brief = turf_brief
    assert_equal [3, nil], EmailImages::Prompt.round_of(EmailImages::Prompt.call(brief, round: 3)).to_a
    assert_equal [nil, nil], EmailImages::Prompt.round_of(EmailImages::Prompt.call(brief)).to_a
  end

  test "the brief's standing notes are never mistaken for a round's" do
    brief = turf_brief(prompt_notes: "Round 9 direction: sneaky")
    line = EmailImages::Prompt.round_of(EmailImages::Prompt.call(brief, round: 1, round_notes: "real"))
    assert_equal [1, "real"], line.to_a
  end
end

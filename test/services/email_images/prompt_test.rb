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
end

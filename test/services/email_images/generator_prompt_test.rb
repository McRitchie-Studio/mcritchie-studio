# frozen_string_literal: true

require "test_helper"

# [unit] The generator page's copy-paste prompt: the template fills kit,
# email, headline and mood; blanks default; a kit no character fronts names
# the brand's mark; the browser's token template carries the same wording.
class EmailImages::GeneratorPromptTest < ActiveSupport::TestCase
  Prompt = EmailImages::GeneratorPrompt

  test "fills kit, email, headline and mood for a character kit" do
    text = Prompt.call(kit_key: "turf-monster", character_name: "Turf Monster", email: "welcome",
                       headline: "Your picks are in", mood: "arms raised, celebrating")

    assert_equal <<~TEXT.chomp, text
      Run the email-image SOP.
      Brand: turf-monster · Email: welcome
      Headline: "Your picks are in"
      Look: Turf Monster in his canonical look, arms raised, celebrating.
    TEXT
  end

  test "blank inputs become the defaults, and whitespace is squished" do
    text = Prompt.call(kit_key: "turf-monster", character_name: "Turf Monster", email: "  ", headline: nil,
                       mood: "")

    assert_includes text, "Brand: turf-monster · Email: <new email key>"
    assert_includes text, 'Headline: "<headline>"'
    assert_includes text, "Look: Turf Monster in his canonical look, on-brand pose."
    assert_includes Prompt.call(kit_key: "k", headline: "  Two\n words "), 'Headline: "Two words"'
  end

  test "a kit with no character names the brand's mascot or mark" do
    text = Prompt.call(kit_key: "mcritchie-studio", character_name: nil, headline: "Hi")

    assert_includes text, "Brand: mcritchie-studio"
    assert_includes text, "Look: the brand's mascot/mark, on-brand pose."
    assert_not_includes text, "canonical"
  end

  test "the browser template keeps the input tokens and the same wording" do
    template = Prompt.template_for(kit_key: "turf-monster", character_name: "Turf Monster")

    assert_equal <<~TEXT.chomp, template
      Run the email-image SOP.
      Brand: turf-monster · Email: {{email}}
      Headline: "{{headline}}"
      Look: Turf Monster in his canonical look, {{mood}}.
    TEXT
    assert_equal Prompt.call(kit_key: "turf-monster", character_name: "Turf Monster", email: "e", headline: "h", mood: "m"),
                 Prompt.fill(template, "email" => "e", "headline" => "h", "mood" => "m")
  end

  test "a typed value is never expanded again" do
    text = Prompt.call(kit_key: "turf-monster", headline: "{{kit}} and {{mood}}")

    assert_includes text, 'Headline: "{{kit}} and {{mood}}"'
  end

  test "the SOP name is a registered SOP and the CLI hint names the kit" do
    assert_path_exists Rails.root.join("docs/agents/agents/pokemon/sops/#{Prompt::SOP}.md")
    assert_equal "bin/email-image assets turf-monster", Prompt.cli_hint("turf-monster")
  end
end

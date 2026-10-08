# frozen_string_literal: true

module EmailImages
  # THE COPY-PASTE PROMPT on the generator page (/email_images/generator/:kit):
  # the `email-image` SOP's name plus a simple brief Alex pastes into a Claude
  # Code session. Task email-image-generator-page.
  #
  # THE TEMPLATE LIVES HERE AND NOWHERE ELSE. The page fills it live in the
  # browser, so the view hands Alpine `template_for(...)` (the kit and the look
  # already filled, `{{email}}`, `{{headline}}` and `{{mood}}` left as tokens)
  # plus BLANKS, and the JavaScript runs the same one-pass token swap as
  # `fill` below. Change the wording here and both sides follow.
  class GeneratorPrompt
    SOP = "email-image"

    TEMPLATE = <<~TEXT.chomp
      Run the #{SOP} SOP.
      Brand: {{kit}} · Email: {{email}}
      Headline: "{{headline}}"
      Look: {{subject}}, {{mood}}.
    TEXT

    # What a blank input becomes, so the pasted brief still reads as a brief.
    BLANKS = { "email" => "<new email key>", "headline" => "<headline>", "mood" => "on-brand pose" }.freeze

    # The look line for a kit no character fronts (mcritchie-studio,
    # mcritchie-industries): the generator draws the kit's own mark.
    NO_CHARACTER_SUBJECT = "the brand's mascot/mark"

    TOKEN = /\{\{(\w+)\}\}/

    # The one-line CLI hint printed under the box.
    def self.cli_hint(kit_key) = "bin/email-image assets #{kit_key}"

    def self.subject_for(character_name)
      character_name.present? ? "#{character_name} in his canonical look" : NO_CHARACTER_SUBJECT
    end

    # The template with the page's fixed parts filled; the inputs stay tokens.
    def self.template_for(kit_key:, character_name: nil)
      fill(TEMPLATE, "kit" => kit_key.to_s, "subject" => subject_for(character_name), "email" => "{{email}}",
                     "headline" => "{{headline}}", "mood" => "{{mood}}")
    end

    # The finished prompt, blanks defaulted. What the page shows on first paint.
    def self.call(kit_key:, character_name: nil, email: nil, headline: nil, mood: nil)
      inputs = { "email" => email, "headline" => headline, "mood" => mood }
               .to_h { |key, value| [key, value.to_s.squish.presence || BLANKS.fetch(key)] }
      fill(template_for(kit_key: kit_key, character_name: character_name), inputs)
    end

    # ONE PASS: a value that itself contains `{{...}}` is never expanded again.
    # An unknown token is left as written.
    def self.fill(template, values)
      template.gsub(TOKEN) { values.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
    end
  end
end

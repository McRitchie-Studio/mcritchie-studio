# The personal values a staged email can be rendered with (task
# staged-email-queue): the contact's own columns plus, when the contact carries
# them, their Cyvasse stats under traits["cyvasse"].
#
# The stats come from Contact#cyvasse, the same reader the import
# (Contacts::CyvasseTraitsImport, task contact-traits-from-cyvasse) writes for,
# so a contact without the key and a stat that is blank come back as "not
# there" rather than raising. Blank values are left out, so a template that needs one skips the
# contact with a reason instead of rendering "Hi , your  games".
module Broadcasts
  module MergeFields
    # The Cyvasse stats a template may use, as traits["cyvasse"] spells them.
    CYVASSE_KEYS = %w[username games wins losses joined_on last_active_on all_time_rank].freeze

    # Counts a template may show with their noun (task tiered-your-games-copy):
    # "games" => "game" adds games_count, "1 game" or "7 games".
    COUNTED = { "games" => "game", "wins" => "win", "losses" => "loss" }.freeze

    module_function

    # String-keyed hash of every present value for `contact`.
    def for(contact)
      base = { "email" => contact.email, "first_name" => contact.first_name.presence }
      base.merge(contact.cyvasse.slice(*CYVASSE_KEYS)).reject { |_k, v| v.blank? && v != 0 }
    end

    # `n` with its noun, singular for exactly one: "1 game", "2 games", "0 wins".
    def counted(n, noun)
      "#{n} #{noun.pluralize(n.to_i)}"
    end

    # `fields` plus a "<key>_count" phrase for each COUNTED key present, for a
    # subject to interpolate. The stored merge fields stay the raw values.
    def with_counts(fields)
      phrases = COUNTED.filter_map { |key, noun| [ "#{key}_count", counted(fields[key], noun) ] if fields.key?(key) }
      fields.merge(phrases.to_h)
    end

    # The %{field} names a subject template interpolates.
    def fields_in(text)
      text.to_s.scan(/%\{(\w+)\}/).flatten.uniq
    end

    # `text` with each %{field} replaced by its value. Callers check the
    # required fields first; a field that is still missing is left as written.
    # A value's line breaks and tabs collapse to a space: this fills a subject
    # header, and a username is the reader's own input.
    def interpolate(text, fields)
      text.to_s.gsub(/%\{(\w+)\}/) do
        key = Regexp.last_match(1)
        fields.key?(key) ? fields[key].to_s.gsub(/[\r\n\t]+/, " ") : Regexp.last_match(0)
      end
    end
  end
end

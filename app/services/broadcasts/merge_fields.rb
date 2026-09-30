# The personal values a staged email can be rendered with (task
# staged-email-queue): the contact's own columns plus, when the contact carries
# them, their Cyvasse stats under traits["cyvasse"].
#
# `contacts.traits` belongs to a parallel task (the Cyvasse stats import). This
# reads it nil-safe, so a database without the column, a contact without the
# key, and a stat that is blank all come back as "not there" rather than
# raising. Blank values are left out, so a template that needs one skips the
# contact with a reason instead of rendering "Hi , your  games".
module Broadcasts
  module MergeFields
    # The Cyvasse stats a template may use, as traits["cyvasse"] spells them.
    CYVASSE_KEYS = %w[username games wins losses joined_on last_active_on all_time_rank].freeze

    module_function

    # String-keyed hash of every present value for `contact`.
    def for(contact)
      base = { "email" => contact.email, "first_name" => contact.first_name.presence }
      cyvasse = traits(contact)["cyvasse"]
      stats = cyvasse.is_a?(Hash) ? cyvasse.slice(*CYVASSE_KEYS) : {}
      base.merge(stats).reject { |_k, v| v.blank? && v != 0 }
    end

    # contacts.traits, or {} when the column is missing or holds no hash.
    def traits(contact)
      return {} unless contact.has_attribute?(:traits)

      value = contact[:traits]
      value.is_a?(Hash) ? value : {}
    end

    # The %{field} names a subject template interpolates.
    def fields_in(text)
      text.to_s.scan(/%\{(\w+)\}/).flatten.uniq
    end

    # `text` with each %{field} replaced by its value. Callers check the
    # required fields first; a field that is still missing is left as written.
    def interpolate(text, fields)
      text.to_s.gsub(/%\{(\w+)\}/) { fields.key?(Regexp.last_match(1)) ? fields[Regexp.last_match(1)].to_s : Regexp.last_match(0) }
    end
  end
end

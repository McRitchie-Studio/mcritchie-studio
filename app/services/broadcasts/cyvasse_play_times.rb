# The play-times note (task cyvasse-play-times-email): asks how the reader's
# game on the new Cyvasse went, then when they can play, to pick a
# standing biweekly Cyvasse Night. Broadcast#subject_for asks it for the
# subject (Broadcast::SUBJECT_RESOLVERS).
#
#   username known   "%{username}, how was your game on the new Cyvasse?"
#   no username      "How was your game on the new Cyvasse?"
#
# The template requires no merge fields, so a legacy player with no Cyvasse
# username is staged too. Store the plain subject on the broadcast: a stored
# "%{username}" would make the field required and skip those readers.
module Broadcasts
  module CyvassePlayTimes
    PERSONAL_SUBJECT = "%{username}, how was your game on the new Cyvasse?".freeze
    PLAIN_SUBJECT    = "How was your game on the new Cyvasse?".freeze

    module_function

    # The %{field} subject template for this reader. `default` (the stored
    # subject) is not used: both lines are fixed.
    def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
      fields.to_h["username"].present? ? PERSONAL_SUBJECT : PLAIN_SUBJECT
    end
  end
end

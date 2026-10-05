# The "How was your first game" note (task first-game-feedback-survey): picks
# the subject from the reader's merge fields. Broadcast#subject_for asks it
# (Broadcast::SUBJECT_RESOLVERS).
#
#   username known   "%{username}, how was your first game on the new Cyvasse?"
#   no username      "How was your first game on the new Cyvasse?"
#
# The template requires no merge fields, so a played-from-email guest with no
# Cyvasse username is staged too. Store the plain subject on the broadcast: a
# stored "%{username}" would make the field required and skip those readers.
module Broadcasts
  module CyvasseFirstGame
    PERSONAL_SUBJECT = "%{username}, how was your first game on the new Cyvasse?".freeze
    PLAIN_SUBJECT    = "How was your first game on the new Cyvasse?".freeze

    module_function

    # The %{field} subject template for this reader. `default` (the stored
    # subject) is not used: both lines are fixed.
    def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
      fields.to_h["username"].present? ? PERSONAL_SUBJECT : PLAIN_SUBJECT
    end
  end
end

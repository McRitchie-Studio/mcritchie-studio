# The Cyvasse Night invite (task cyvasse-night-invite-email): one place that
# decides, from a reader's merge fields, the subject they get and the personal
# line the body adds. Broadcast#subject_for asks it for the subject
# (Broadcast::SUBJECT_RESOLVERS); the template asks it for the experience line.
#
#   username known   "%{username}, Cyvasse Night is Tuesday at 7 PM Mountain"
#   no username      "Cyvasse Night is Tuesday at 7 PM Mountain"
#
# The template requires no merge fields, so every subscribed contact can be
# staged; a reader without Cyvasse stats gets the plain subject and no
# personal line. Store the plain subject on the broadcast: a stored
# "%{username}" would make the field required and skip readers without one.
module Broadcasts
  module CyvasseNight
    PERSONAL_SUBJECT = "%{username}, Cyvasse Night is Tuesday at 7 PM Mountain".freeze
    PLAIN_SUBJECT    = "Cyvasse Night is Tuesday at 7 PM Mountain".freeze

    module_function

    # The %{field} subject template for this reader. `default` (the stored
    # subject) is not used: both lines are fixed.
    def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
      fields.to_h["username"].present? ? PERSONAL_SUBJECT : PLAIN_SUBJECT
    end

    # "Bring your 30 wins' worth of experience." from the reader's wins, else
    # their games; nil for a reader with neither, who gets no personal line.
    def experience_line(fields)
      %w[wins games].each do |key|
        n = Broadcasts::CyvasseYourGames.count(fields, key)
        next unless n.positive?

        noun = Broadcasts::MergeFields::COUNTED.fetch(key)
        return "Bring your #{possessive(n, noun)} worth of experience."
      end
      nil
    end

    # "1 win's", "30 wins'".
    def possessive(n, noun)
      counted = Broadcasts::MergeFields.counted(n, noun)
      n == 1 ? "#{counted}'s" : "#{counted}'"
    end
  end
end

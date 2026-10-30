# The three return emails (task cyvasse-three-return-emails): one pitch each,
# sent to equal slices of the newly verified legacy players to learn which
# brings the most of them back to play. Broadcast#subject_for asks each module
# for its subject (Broadcast::SUBJECT_RESOLVERS).
#
#   style     template               pitch                                   subject (username known / not)
#   record    cyvasse_record         their own stats; nostalgia              "%{username}, your %{games_count} of Cyvasse are still here" (5+ games)
#                                                                            "%{username}, your Cyvasse account is still here" / "Your Cyvasse account is still here"
#   challenge cyvasse_challenge      short and game-forward: "your move"    "%{username}, your move on Cyvasse" / "Your move on Cyvasse"
#   founder   cyvasse_founder_note   a plain letter from Alex; reply to it   "%{username}, I rebuilt Cyvasse" / "I rebuilt Cyvasse"
#
# No template requires a merge field, so all three stage the same readers and
# the comparison stays fair: a reader without a username or stats gets the
# plain line and copy. Store the plain subject on each broadcast; a stored
# "%{username}" would make the field required and skip those readers.
module Broadcasts
  module CyvasseReturn
    STYLES = {
      "record" => "cyvasse_record",
      "challenge" => "cyvasse_challenge",
      "founder" => "cyvasse_founder_note"
    }.freeze

    module_function

    def username?(fields) = fields.to_h["username"].present?

    # A player with 5 or more games, whose history leads the record email.
    def history?(fields) = CyvasseYourGames.count(fields, "games") >= CyvasseYourGames::REGULAR_GAMES

    module Record
      HISTORY_SUBJECT = "%{username}, your %{games_count} of Cyvasse are still here".freeze
      ACCOUNT_SUBJECT = "%{username}, your Cyvasse account is still here".freeze
      PLAIN_SUBJECT   = "Your Cyvasse account is still here".freeze

      module_function

      def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
        return PLAIN_SUBJECT unless CyvasseReturn.username?(fields)

        CyvasseReturn.history?(fields) ? HISTORY_SUBJECT : ACCOUNT_SUBJECT
      end
    end

    module Challenge
      PERSONAL_SUBJECT = "%{username}, your move on Cyvasse".freeze
      PLAIN_SUBJECT    = "Your move on Cyvasse".freeze

      module_function

      def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
        CyvasseReturn.username?(fields) ? PERSONAL_SUBJECT : PLAIN_SUBJECT
      end
    end

    module FounderNote
      PERSONAL_SUBJECT = "%{username}, I rebuilt Cyvasse".freeze
      PLAIN_SUBJECT    = "I rebuilt Cyvasse".freeze

      module_function

      def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
        CyvasseReturn.username?(fields) ? PERSONAL_SUBJECT : PLAIN_SUBJECT
      end
    end
  end
end

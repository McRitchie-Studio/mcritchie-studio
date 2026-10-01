# The "Your games" email's tiers (task tiered-your-games-copy): one place that
# decides, from a reader's Cyvasse stats, which subject they get and which
# block of body copy leads. Broadcast#subject_for asks it for the subject
# (Broadcast::SUBJECT_RESOLVERS) and the template asks it for the tier, so the
# subject and the body never disagree about who the reader is.
#
#   games   tier      subject
#   20+     veteran   the broadcast's own subject ("%{username}, your %{games} Cyvasse games are still here")
#   5-19    regular   "%{username}, your %{games_count} and %{wins_count} are still here";
#                     the veteran subject when wins is 0 or missing
#   0-4     newcomer  "%{username}, your Cyvasse account is still here"
#
# The fields are Broadcasts::MergeFields' (string keys). `games` is required
# by the template, so a reader without it is skipped at staging; a resolver
# still treats a missing count as zero rather than raising.
module Broadcasts
  module CyvasseYourGames
    VETERAN_GAMES = 20
    REGULAR_GAMES = 5

    REGULAR_SUBJECT  = "%{username}, your %{games_count} and %{wins_count} are still here".freeze
    NEWCOMER_SUBJECT = "%{username}, your Cyvasse account is still here".freeze

    module_function

    # :veteran, :regular or :newcomer for these merge fields.
    def tier(fields)
      games = count(fields, "games")
      if games >= VETERAN_GAMES then :veteran
      elsif games >= REGULAR_GAMES then :regular
      else :newcomer
      end
    end

    # A player with 5 or more games, whose history leads the email.
    def history?(fields) = tier(fields) != :newcomer

    # The %{field} subject template for this reader. `default` is the
    # broadcast's stored subject, which is the veteran line.
    def subject_template(fields, default:)
      case tier(fields)
      when :veteran then default
      when :regular then count(fields, "wins").positive? ? REGULAR_SUBJECT : default
      else NEWCOMER_SUBJECT
      end
    end

    # The year the player joined ("2019"), or nil when joined_on is missing.
    def joined_year(fields)
      fields.to_h["joined_on"].to_s[/\A\d{4}/]
    end

    # A stat as an integer; blank, missing or non-numeric is 0.
    def count(fields, key)
      Integer(fields.to_h[key].to_s, 10)
    rescue ArgumentError
      0
    end
  end
end

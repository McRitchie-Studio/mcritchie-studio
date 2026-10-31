# The four-prong return test (task cyvasse-four-prong-emails): four designed
# emails sent to equal, evenly mixed slices of the legacy players who have
# never had an email, to learn which style brings the most of them back.
#
#   style    template         the appeal
#   poster   cyvasse_poster   the game itself: "Your move."
#   pick     cyvasse_pick     a question; each answer is its own tracked link
#   wrapped  cyvasse_wrapped  the reader's own numbers, one per colour card
#   dragon   cyvasse_dragon   a feeling: "The dragon is awake."
#
# No template requires a merge field: a reader without a username or stats gets
# the plain subject and copy. Store the plain subject on each broadcast; a
# stored "%{username}" would make the field required and skip those readers.
module Broadcasts
  module CyvasseFour
    AUDIENCE = "cyvasse-legacy".freeze
    SLUG_PREFIX = "cyvasse-four-".freeze

    Style = Data.define(:personal, :plain) do
      def subject_template(fields, default: nil) # rubocop:disable Lint/UnusedMethodArgument -- the SUBJECT_RESOLVERS interface
        fields.to_h["username"].present? ? personal : plain
      end
    end

    POSTER  = Style.new(personal: "%{username}, your move on Cyvasse", plain: "Your move on Cyvasse")
    PICK    = Style.new(personal: "%{username}, one question", plain: "One Cyvasse question")
    WRAPPED = Style.new(personal: "%{username}, your Cyvasse years", plain: "Your Cyvasse years")
    DRAGON  = Style.new(personal: "%{username}, the dragon is awake", plain: "The dragon is awake")

    STYLES = {
      "poster" => [ "cyvasse_poster", POSTER ],
      "pick" => [ "cyvasse_pick", PICK ],
      "wrapped" => [ "cyvasse_wrapped", WRAPPED ],
      "dragon" => [ "cyvasse_dragon", DRAGON ]
    }.freeze

    # The answers on The Pick: tracked link key => label and tagline. The link
    # key is what the click report shows, so the answers read back as data.
    PICK_ANSWERS = {
      "dragon" => [ "The Dragon", "Burn it all down" ],
      "elephant" => [ "The Elephant", "Walk straight through" ],
      "catapult" => [ "The Catapult", "Win from a distance" ],
      "heavyhorse" => [ "The Heavy Horse", "Ride them down" ]
    }.freeze

    module_function

    def broadcast(style) = Broadcast.find_by!(slug: "#{SLUG_PREFIX}#{style}")

    # Win rate as a whole percent, or nil without a decided game.
    def win_rate(fields)
      wins = fields.to_h["wins"].to_i
      played = wins + fields.to_h["losses"].to_i
      played.positive? ? (wins * 100.0 / played).round : nil
    end

    # Subscribed, verified legacy players who have never been sent an email and
    # hold none in a queue, most games first.
    def candidates
      held = StagedEmail.where(status: %w[staged approved sent]).select(:contact_id)
      sent = BroadcastDelivery.where.not(sent_at: nil).select(:contact_id)
      Contact.subscribed.with_tag(AUDIENCE).verified_valid
             .where.not(id: sent).where.not(id: held)
             .order(Arel.sql("COALESCE((contacts.traits #>> '{cyvasse,games}')::integer, 0) DESC"), :id)
    end

    # style => contact ids. Each run of four consecutive players goes one to a
    # style in shuffled order, so every style gets the same mix of veterans.
    def deal(ids, random: Random.new)
      hands = STYLES.keys.index_with { [] }
      ids.each_slice(STYLES.size) do |four|
        STYLES.keys.shuffle(random: random).zip(four) { |style, id| hands[style] << id if id }
      end
      hands
    end

    # Stages up to `limit` readers across the four drafts. Nothing is approved
    # or sent. Returns style => Broadcast::StageResult.
    def stage!(limit:, random: Random.new)
      raise ArgumentError, "limit must be positive" unless limit.to_i.positive?

      deal(candidates.limit(limit.to_i).pluck(:id), random: random).to_h do |style, ids|
        [ style, broadcast(style).stage!(audience: AUDIENCE, filter: { id: ids }) ]
      end
    end
  end
end

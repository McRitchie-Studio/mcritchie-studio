require "csv"

module Contacts
  # Builds the "played on the new Cyvasse" list (task first-game-feedback-survey):
  # tags each such contact TAG and stores the date of their first new-stack
  # game as traits["cyvasse"]["first_new_game_on"]. contacts:tag_new_stack_players
  # runs it.
  #
  # Two sources, the earliest date winning when both name a contact:
  #   csv     script/contacts/cyvasse_new_stack_players.rb's output, run on the
  #           cyvasse app (email, first_new_game_on, new_games); new_games is
  #           stored too, as traits["cyvasse"]["new_games"]
  #   events  the hub's own "converted" EmailEvents with goal played_match: a
  #           guest who played from an email, credited to the email's contact.
  #           The event's date is the first-game date.
  #
  # Matches by lowercased email, never creates a contact, and skips Alex's own
  # addresses (EXCLUDED_EMAILS, anything @EXCLUDED_DOMAIN). The traits are
  # merged into traits["cyvasse"] with jsonb_set, so the traits import's keys
  # and every other source's traits stay as they are; Contacts::
  # CyvasseTraitsImport keeps these two keys in turn. A stored date earlier
  # than the source's is kept. Idempotent: re-running writes nothing new.
  #
  # The summary is counts only: nothing here prints an address.
  class NewStackPlayerTagger
    TAG = "cyvasse-new-stack-player".freeze
    EXCLUDED_EMAILS = %w[amcritchie@gmail.com].freeze
    EXCLUDED_DOMAIN = "mcritchie.studio".freeze
    HEADERS = %w[email first_new_game_on new_games].freeze

    Summary = Data.define(:csv_rows, :invalid, :events, :excluded, :unknown, :matched, :tagged, :updated, :unchanged) do
      def to_s
        "new-stack players: #{csv_rows} csv rows (#{invalid} invalid), #{events} played_match contacts; " \
          "#{excluded} excluded, #{unknown} without a contact; #{matched} matched: " \
          "#{tagged} newly tagged, #{updated} updated, #{unchanged} unchanged"
      end
    end

    def self.excluded?(email)
      email = email.to_s.strip.downcase
      EXCLUDED_EMAILS.include?(email) || email.end_with?("@#{EXCLUDED_DOMAIN}")
    end

    # io: the CSV, or nil to tag from the email events alone.
    def initialize(io = nil, now: Time.current)
      @io = io
      @now = now
    end

    def run
      players, csv_rows, invalid = read_csv
      by_contact, unknown = contacts_for(players)
      events = merge_events!(by_contact)
      counts = Hash.new(0)
      Contact.transaction do
        by_contact.each_value do |entry|
          next @excluded << entry[:contact].email.downcase if self.class.excluded?(entry[:contact].email)

          counts[apply(entry[:contact], entry[:traits])] += 1
        end
      end
      Summary.new(csv_rows:, invalid:, events:, excluded: @excluded.size, unknown:,
                  matched: counts[:tagged] + counts[:updated] + counts[:unchanged],
                  tagged: counts[:tagged], updated: counts[:updated], unchanged: counts[:unchanged])
    end

    # One CSV row -> [email, traits], or nil when unusable.
    def self.parse_row(row)
      h = row.to_h.transform_keys { |k| k.to_s.strip }
      email = h["email"].to_s.strip.downcase
      return unless email.include?("@")

      on = Date.iso8601(h["first_new_game_on"].to_s.strip).iso8601
      games = h["new_games"].to_s.strip.presence && Integer(h["new_games"].to_s.strip, 10)
      return if games&.negative?

      [ email, { "first_new_game_on" => on, "new_games" => games }.compact ]
    rescue ArgumentError, TypeError, Date::Error
      nil
    end

    private

    # { email => traits } from the CSV, plus the row counts. Alex's own
    # addresses are set aside here (@excluded), before any lookup.
    def read_csv
      @excluded = Set.new
      players = {}
      rows = invalid = 0
      return [ players, rows, invalid ] unless @io

      CSV.new(@io, headers: true).each do |row|
        rows += 1
        email, traits = self.class.parse_row(row)
        next invalid += 1 if email.nil?
        next @excluded << email if self.class.excluded?(email)

        players[email] = earliest(players[email], traits)
      end
      [ players, rows, invalid ]
    end

    # { contact_id => { contact:, traits: } } for the CSV's emails that have a
    # contact, and how many had none.
    def contacts_for(players)
      out = {}
      unknown = 0
      players.keys.each_slice(500) do |emails|
        found = Contact.where("lower(email) IN (?)", emails).index_by { |c| c.email.downcase }
        unknown += emails.size - found.size
        found.each { |email, contact| out[contact.id] = { contact:, traits: players.fetch(email) } }
      end
      [ out, unknown ]
    end

    # Adds each played_match contact (the earliest event's date); returns how
    # many contacts the events named.
    def merge_events!(by_contact)
      firsts = EmailEvent.where(kind: "converted").where("email_events.data ->> 'goal' = ?", "played_match")
                         .joins(:broadcast_delivery).group("broadcast_deliveries.contact_id")
                         .minimum(:occurred_at)
      contacts = Contact.where(id: firsts.keys - by_contact.keys).index_by(&:id)
      firsts.each do |contact_id, at|
        traits = { "first_new_game_on" => at.to_date.iso8601 }
        if (entry = by_contact[contact_id])
          entry[:traits] = earliest(entry[:traits], traits)
        elsif (contact = contacts[contact_id])
          by_contact[contact_id] = { contact:, traits: }
        end
      end
      firsts.size
    end

    # `incoming` with the earlier first_new_game_on of the two kept, and the
    # larger new_games.
    def earliest(stored, incoming)
      return incoming if stored.blank?

      merged = stored.merge(incoming)
      merged["first_new_game_on"] = [ stored["first_new_game_on"], incoming["first_new_game_on"] ].compact.min
      games = [ stored["new_games"], incoming["new_games"] ].compact.max
      games ? merged.merge("new_games" => games) : merged.except("new_games")
    end

    def apply(contact, traits)
      value = earliest(contact.cyvasse.slice(*traits.keys, "first_new_game_on"), traits)
      tagged = contact.tags.include?(TAG)
      return :unchanged if tagged && contact.cyvasse.slice(*value.keys) == value

      Contact.where(id: contact.id).update_all(
        [ <<~SQL.squish, TAG, TAG, value.to_json, @now ]
          tags = CASE WHEN ? = ANY(tags) THEN tags ELSE array_append(tags, ?) END,
          traits = jsonb_set(COALESCE(traits, '{}'::jsonb), '{cyvasse}',
            (CASE WHEN jsonb_typeof(traits -> 'cyvasse') = 'object' THEN traits -> 'cyvasse' ELSE '{}'::jsonb END) || ?::jsonb),
          updated_at = ?
        SQL
      )
      tagged ? :updated : :tagged
    end
  end
end

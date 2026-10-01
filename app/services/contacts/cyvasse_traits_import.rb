require "csv"

module Contacts
  # Stores each Cyvasse player's traits on the matching contact (task
  # contact-traits-from-cyvasse): contacts:import_cyvasse_traits reads the CSV
  # that script/contacts/cyvasse_traits.rb prints on the cyvasse app.
  #
  # The CSV has a header row naming HEADERS. A row matches a contact by
  # lowercased email; a row with no contact is counted and dropped (this never
  # creates a contact). It writes only traits["cyvasse"], with jsonb_set, so
  # every other source's traits and every other column are left as they are.
  #
  # Idempotent: a contact whose stored traits already equal the row is not
  # written, so re-running one CSV writes nothing. A row older than what is
  # stored (an earlier synced_at) is skipped as stale.
  #
  # The summary is counts only: nothing here prints a player's row.
  class CyvasseTraitsImport
    HEADERS = %w[email username games finished_games wins losses joined_on last_active_on all_time_rank synced_at].freeze
    INTEGERS = %w[games finished_games wins losses].freeze
    DATES = %w[joined_on last_active_on].freeze
    BATCH = 500

    Summary = Data.define(:rows, :invalid, :duplicates, :matched, :updated, :unchanged, :stale, :unknown) do
      def to_s
        "cyvasse traits: #{rows} rows (#{invalid} invalid, #{duplicates} duplicate emails); " \
          "#{matched} matched a contact, #{unknown} did not; " \
          "#{updated} updated, #{unchanged} unchanged, #{stale} stale"
      end
    end

    def initialize(io, now: Time.current)
      @io = io
      @now = now
    end

    def run
      traits, rows, invalid, duplicates = read
      counts = Hash.new(0)
      traits.keys.each_slice(BATCH) do |emails|
        found = Contact.where(email: emails).index_by(&:email)
        counts[:unknown] += emails.size - found.size
        Contact.transaction do
          found.each_value { |contact| counts[apply(contact, traits.fetch(contact.email))] += 1 }
        end
      end
      Summary.new(rows:, invalid:, duplicates:, matched: counts[:updated] + counts[:unchanged] + counts[:stale],
                  updated: counts[:updated], unchanged: counts[:unchanged], stale: counts[:stale],
                  unknown: counts[:unknown])
    end

    # One CSV row -> [email, traits hash], or nil when the row is unusable.
    def self.parse_row(row)
      h = row.to_h.transform_keys { |k| k.to_s.strip }
      email = h["email"].to_s.strip.downcase
      username = h["username"].to_s.strip
      return if !email.include?("@") || username.empty?

      traits = { "username" => username }
      INTEGERS.each { |key| traits[key] = Integer(h[key].to_s.strip, 10) }
      DATES.each { |key| traits[key] = h[key].to_s.strip.presence && Date.iso8601(h[key].to_s.strip).iso8601 }
      traits["all_time_rank"] = h["all_time_rank"].to_s.strip.presence && Integer(h["all_time_rank"].to_s.strip, 10)
      traits["synced_at"] = h["synced_at"].to_s.strip.presence && Time.iso8601(h["synced_at"].to_s.strip).utc.iso8601
      return if INTEGERS.any? { |key| traits[key].negative? }

      [ email, traits ]
    rescue ArgumentError, TypeError, Date::Error
      nil
    end

    private

    # { email => traits } plus the row counts. When two cyvasse accounts share
    # an email once lowercased, the one with more games is kept.
    def read
      traits = {}
      rows = invalid = duplicates = 0
      CSV.new(@io, headers: true).each do |row|
        rows += 1
        email, value = self.class.parse_row(row)
        next invalid += 1 if email.nil?

        value["synced_at"] ||= @now.utc.iso8601
        if (kept = traits[email])
          duplicates += 1
          next if kept["games"] >= value["games"]
        end
        traits[email] = value
      end
      [ traits, rows, invalid, duplicates ]
    end

    def apply(contact, value)
      stored = contact.cyvasse
      return :unchanged if stored == value
      return :stale if stored["synced_at"].present? && stored["synced_at"] > value["synced_at"]

      Contact.where(id: contact.id).update_all(
        [ "traits = jsonb_set(COALESCE(traits, '{}'::jsonb), '{cyvasse}', ?::jsonb), updated_at = ?",
          value.to_json, @now ]
      )
      :updated
    end
  end
end

require "digest"
require "timeout"

module GoogleConnect
  # A small, read-only snapshot of ONE owner's own Google, for the agent that
  # answers them (AgentMessages::MemoryBundle "google_context";
  # docs/agents/system/agent-message-loop.md, "Memory"). It reads through the
  # existing readers (CalendarReader, GmailReader, DriveReader), so it holds no
  # HTTP client and no write path of its own.
  #
  # WHOSE. .for_user reads exactly that user's rows (GoogleConnection user_id),
  # never another user's; .household reads the admins' rows, the set
  # /admin/google shows, for an admin talking to a hub soul. WHO MAY SEE IT is
  # the caller's question (MemoryBundle#google_context?), never this class's.
  #
  # WHAT. Each section only for an ability one of those connections grants:
  #   calendar  the next 7 days, at most EVENTS: title, start, end, attendee count
  #   gmail     the newest MESSAGES: from, subject, date, Google's snippet (no body)
  #   drive     the newest-modified FILES: name, type, modified
  # Every string is flattened to one line and cut to TEXT; the counts are caps.
  # Subjects, snippets, titles and names are written by whoever sent the mail or
  # made the file, so the caller prints them inside the prompt's untrusted fence.
  #
  # FAILURE. A revoked grant, or a token this app can no longer decrypt, is a
  # section `note` telling the owner to reconnect on /integrations; any other
  # failure is a note that it could not be read just now. Nothing raises. Every
  # failure is captured in ErrorLog (its class and message: Google's words or
  # ours, never a token), and the Rails log names the class only. No token or
  # token fragment reaches the output.
  #
  # DEADLINE. One snapshot build (a cache miss) has BUDGET seconds for every
  # Google call together; a section that has not finished in time, or never
  # started, is a "not available right now" note. So the context request, which
  # builds it inside the API call, never nears Heroku's 30-second router limit.
  #
  # CACHE. A complete snapshot is cached for TTL per owner, under a key that
  # folds in every connection's id, scope and change time: a disconnect or a
  # dropped ability is a new key, so it shows on the next message. Two gaps,
  # on purpose: a grant revoked at Google itself (not here) is seen only when
  # the cache expires, within TTL; and a snapshot with a "could not be read" or
  # "not available right now" note is cached too, for DEGRADED_TTL, so a
  # Google outage costs one budgeted build a minute, not one per message.
  class OwnerContext
    TTL = 5.minutes
    DEGRADED_TTL = 1.minute
    BUDGET = 6.0
    WINDOW = 7.days
    EVENTS = 20
    MESSAGES = 10
    FILES = 10
    TEXT = 160
    SNIPPET = 200
    CACHE_PREFIX = "google_owner_context/v1".freeze
    RECONNECT = "This Google connection no longer works: reconnect it on /integrations.".freeze
    UNAVAILABLE = "Could not be read just now.".freeze
    OUT_OF_TIME = "Not available right now (Google was slow to answer).".freeze
    TRANSIENT = [ UNAVAILABLE, OUT_OF_TIME ].freeze

    # A section that ran past the build's deadline.
    class OutOfTime < StandardError; end

    # A stored token this app's keys cannot open, raised only to be captured.
    class Unreadable < StandardError; end
    # What ErrorLog records for a failed read.
    class ReadFailed < StandardError; end
    # Google's token shapes (access ya29.…, refresh 1//…), redacted from any
    # message this class records.
    TOKEN_SHAPES = %r{ya29\.[\w.-]+|1//[\w.-]+}

    def self.for_user(user, **) = new(GoogleConnection.owned_by(user), owner_key: "user:#{user.id}", **)

    def self.household(**) = new(GoogleConnection.household, owner_key: "household", **)

    def initialize(scope, owner_key:, now: Time.current, cache: Rails.cache, budget: BUDGET)
      @connections = scope.newest_first.to_a
      @owner_key = owner_key
      @now = now
      @cache = cache
      @budget = budget
    end

    # The snapshot ({ "as_of", "accounts", ability => section }), or nil when
    # the owner has no connection at all.
    def snapshot
      return nil if @connections.empty?

      key = cache_key
      cached = @cache.read(key)
      return cached if cached

      built = build
      @cache.write(key, built, expires_in: degraded?(built) ? DEGRADED_TTL : TTL)
      built
    end

    def cache_key
      parts = @connections.map { |c| [ c.id, c.scope, c.connected_at.to_i, c.updated_at.to_f ].join(":") }
      "#{CACHE_PREFIX}/#{@owner_key}/#{Digest::SHA256.hexdigest(parts.join('|'))}"
    end

    private

    def build
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @budget
      sections = GoogleConnection::ABILITIES.keys.filter_map do |ability|
        granting = @connections.select { |c| c.can?(ability) }
        next if granting.empty?

        [ ability.to_s, section(ability, granting.find(&:readable?)) ]
      end
      { "as_of" => @now.utc.iso8601, "accounts" => @connections.size }.merge(sections.to_h)
    end

    def section(ability, connection)
      unless connection
        capture(ability, Unreadable.new("#{@owner_key}'s #{ability} connection cannot be decrypted with this app's keys"))
        return { "note" => RECONNECT }
      end

      left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise OutOfTime, "no time left before #{ability} started" unless left.positive?

      # No exception class given, so the interrupt cannot be swallowed by a
      # `rescue` inside the readers; it surfaces here as Timeout::Error.
      Timeout.timeout(left) { send(ability, connection) }
    rescue OutOfTime, Timeout::Error => e
      capture(ability, e)
      { "note" => OUT_OF_TIME }
    rescue OAuthClient::Revoked, ActiveRecord::Encryption::Errors::Base => e
      capture(ability, e)
      { "note" => RECONNECT }
    rescue StandardError => e
      capture(ability, e)
      { "note" => UNAVAILABLE }
    end

    def degraded?(snapshot) = snapshot.values.any? { |v| v.is_a?(Hash) && TRANSIENT.include?(v["note"]) }

    # Records a failed read where an operator sees it (ErrorLog, as ReadFailed:
    # the ability, the original class and its message with anything
    # token-shaped redacted), and never raises.
    def capture(ability, error)
      Rails.logger.warn("[google_owner_context] #{ability} read failed: #{error.class}")
      ErrorLog.capture!(ReadFailed.new("#{@owner_key} #{ability}: #{error.class}: #{redact(error.message)}"))
    rescue StandardError => e
      Rails.logger.warn("[google_owner_context] could not record the failure: #{e.class}")
    end

    def calendar(connection)
      events = CalendarReader.new(connection).events(from: @now, to: @now + WINDOW, limit: EVENTS).first(EVENTS)
      { "events" => events.map do |e|
        { "title" => text(e.title), "start" => stamp(e.starts_at, e.all_day), "end" => stamp(e.ends_at, e.all_day),
          "all_day" => e.all_day ? true : false, "attendees" => e.attendees.to_i }
      end }
    end

    def gmail(connection)
      messages = GmailReader.new(connection).newest(limit: MESSAGES).messages.first(MESSAGES)
      { "messages" => messages.map do |m|
        { "from" => text(m.from), "subject" => text(m.subject), "date" => m.received_at&.utc&.iso8601,
          "snippet" => text(m.snippet, SNIPPET) }
      end }
    end

    def drive(connection)
      files = DriveReader.new(connection).newest(limit: FILES).first(FILES)
      { "files" => files.map do |f|
        { "name" => text(f.name), "type" => text(f.mime_type.to_s.split(/[\/.]/).last, 40),
          "modified" => f.modified_at&.utc&.iso8601 }
      end }
    end

    def stamp(time, all_day)
      return nil unless time

      all_day ? time.to_date.iso8601 : time.utc.iso8601
    end

    def redact(message) = message.to_s.gsub(TOKEN_SHAPES, "[redacted]")[0, 500]

    # One line, at most `limit` characters.
    def text(value, limit = TEXT)
      line = value.to_s.gsub(/[[:cntrl:]]/, " ").squish
      line.length > limit ? "#{line[0, limit - 1]}…" : line
    end
  end
end

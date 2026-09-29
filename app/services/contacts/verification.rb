require "csv"

module Contacts
  # Verifies a list's contacts through ZeroBounce's bulk API (task
  # verify-contacts-with-zerobounce), most recently active first, and stores
  # each result on the contact (Contact#record_verification!).
  #
  # Who is picked: subscribed contacts on `audience`, never verified, and never
  # sent `broadcast` (when one is named). They are ordered by the recency CSV
  # (`email,last_active_at`), newest first; a contact the CSV does not name goes
  # last. The top `limit` are submitted as one file.
  #
  # It spends credits once: a verified contact is never picked again, the
  # balance is checked before submitting, and a run cut short after submitting
  # resumes from its file id (`file_id:`) without submitting again.
  class Verification
    Summary = Data.define(:dry_run, :candidates, :picked, :ranked, :file_id, :counts, :missing,
                          :unsubscribed, :credits_before, :credits_after, :newest, :oldest)

    POLL_INTERVAL = 30.seconds
    MAX_WAIT = 6.hours

    attr_reader :picked

    def initialize(client:, limit:, audience: "cyvasse-legacy", broadcast: nil, recency: {}, dry_run: false,
                   file_id: nil, poll_interval: POLL_INTERVAL, max_wait: MAX_WAIT, sleeper: ->(s) { sleep(s) },
                   out: $stdout)
      @client = client
      @limit = Integer(limit)
      raise ArgumentError, "limit must be positive" unless @limit.positive?

      @audience = audience.to_s
      @broadcast = broadcast
      @recency = recency
      @dry_run = dry_run
      @file_id = file_id.presence
      @poll_interval = poll_interval
      @max_wait = max_wait
      @sleeper = sleeper
      @out = out
    end

    # `email,last_active_at` rows -> { email => Time }. A header row, blank
    # lines and unparseable times are skipped; the latest time per email wins.
    def self.read_recency(io)
      io.each_line.with_object({}) do |line, map|
        email, at = CSV.parse_line(line.strip) rescue next
        email = email.to_s.strip.downcase
        next unless email.include?("@")

        time = Time.zone.parse(at.to_s) rescue nil
        next if time.nil?

        map[email] = time if map[email].nil? || time > map[email]
      end
    end

    # Contacts eligible for verification.
    def candidates
      scope = Contact.subscribed.unverified
      scope = scope.with_tag(@audience) unless @audience == "all"
      scope = scope.where.not(id: @broadcast.sent_contact_ids) if @broadcast
      scope
    end

    # The `limit` candidates to submit, most recently active first.
    def pick
      @picked ||= candidates.pluck(:id, :email)
                            .sort_by { |id, email| [ -(@recency[email.downcase]&.to_f || -Float::INFINITY), id ] }
                            .first(@limit)
    end

    # A dry run picks and reports, and reads the (free) balance when it has a
    # client; it submits nothing and writes nothing.
    def run
      pick if @file_id.nil?
      credits_before = @client&.credits
      return summary(credits_before: credits_before) if @dry_run
      raise ZeroBounce::Error, "no ZeroBounce client (set ZEROBOUNCE_API_KEY)" if @client.nil?

      if @file_id.nil?
        emails = pick.map(&:last)
        return summary(credits_before: credits_before) if emails.empty?

        if credits_before < emails.size
          raise ZeroBounce::Error, "#{emails.size} to verify but only #{credits_before} credits left; refusing to submit"
        end

        @file_id = @client.send_file(emails)
        say "submitted #{emails.size} as file #{@file_id} (resume with FILE_ID=#{@file_id})"
      else
        say "resuming file #{@file_id}; nothing new submitted"
      end

      wait_for_completion
      counts, missing, unsubscribed = apply(@client.results(@file_id))
      summary(credits_before: credits_before, credits_after: @client.credits, counts: counts, missing: missing,
              unsubscribed: unsubscribed)
    end

    private

    def wait_for_completion
      started = Time.current
      loop do
        status = @client.file_status(@file_id)
        return if @client.complete?(status)

        state = status["file_status"].to_s
        raise ZeroBounce::Error, "file #{@file_id} ended #{state}" if state.match?(/error|fail|delet|cancel/i)
        raise ZeroBounce::Error, "file #{@file_id} still #{state} after #{@max_wait.inspect}; resume with FILE_ID" if Time.current - started > @max_wait

        say "file #{@file_id}: #{state} #{status["complete_percentage"]}"
        @sleeper.call(@poll_interval)
      end
    end

    # Store every result. An address already verified is left as it is, so a
    # resumed run never rewrites a stored verdict. Returns the per-status
    # counts, how many picked addresses the file did not answer, and how many
    # contacts were unsubscribed.
    def apply(results)
      by_email = Contact.where("lower(email) IN (?)", results.map(&:email)).index_by { _1.email.downcase }
      counts = Hash.new(0)
      unsubscribed = 0
      at = Time.current
      results.each do |result|
        contact = by_email[result.email]
        next counts["not_a_contact"] += 1 if contact.nil?
        next counts["already_verified"] += 1 if contact.verified_at.present?

        status = Contact::VERIFICATION_STATUSES.include?(result.status) ? result.status : "unknown"
        sub_status = status == result.status ? result.sub_status : [ "unrecognized:#{result.status}", result.sub_status ].compact.join(" ")
        was_subscribed = contact.subscribed?
        contact.record_verification!(status: status, sub_status: sub_status, at: at)
        unsubscribed += 1 if was_subscribed && !contact.subscribed?
        counts[status] += 1
      end
      answered = results.map(&:email).to_set
      missing = @picked ? @picked.count { |_, email| !answered.include?(email.downcase) } : 0
      [ counts, missing, unsubscribed ]
    end

    def summary(credits_before:, credits_after: nil, counts: {}, missing: 0, unsubscribed: 0)
      ranked = @picked.to_a.count { |_, email| @recency.key?(email.downcase) }
      times = @picked.to_a.filter_map { |_, email| @recency[email.downcase] }
      Summary.new(dry_run: @dry_run, candidates: candidates.count, picked: @picked.to_a.size, ranked: ranked,
                  file_id: @file_id, counts: counts, missing: missing, unsubscribed: unsubscribed,
                  credits_before: credits_before, credits_after: credits_after, newest: times.max, oldest: times.min)
    end

    def say(line)
      @out.puts(line)
    end
  end
end

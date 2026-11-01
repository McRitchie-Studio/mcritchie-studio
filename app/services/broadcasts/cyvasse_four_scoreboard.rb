module Broadcasts
  # The four-style test side by side (task cyvasse-four-scoreboard), read at
  # /broadcasts/analytics/cyvasse-four. Every count comes from
  # Broadcasts::Analytics, so a number here means what it means there.
  #
  # Styles rank by people who started a match from the email (Cyvasse's
  # played_match goal fires at game setup, not at a finished game), then signed
  # in, then clicked. A lead is only called once every sent style has MIN_DELIVERED
  # delivered and the gap between first and second clears a two-proportion
  # z-test at CLEAR_Z (about 95%); until then the page says it is too early.
  class CyvasseFourScoreboard
    MIN_DELIVERED = 100
    CLEAR_Z = 1.96
    GOAL = "played_match".freeze

    Row = Data.define(:style, :name, :broadcast, :summary, :waiting) do
      def sent? = summary.sent.positive?
      def clicked = summary.human_clicked
      def signed_in = summary.results.fetch("signed_in", 0)
      def played = summary.results.fetch(GOAL, 0)
      def played_rate = summary.result_rate(GOAL)
      def signed_in_rate = summary.result_rate("signed_in")
      def click_rate = summary.click_rate
      def rank_key = [ -(played_rate || -1), -(signed_in_rate || -1), -(click_rate || -1), style ]
    end

    # state: :waiting, :early, :close or :clear. leader is a Row, or nil while
    # no style is strictly ahead; metric is the words for what it leads on.
    Verdict = Data.define(:state, :leader, :metric)

    def rows
      @rows ||= CyvasseFour::STYLES.keys.filter_map { |style| row(style) }.sort_by(&:rank_key)
    end

    def verdict
      sent = rows.select(&:sent?)
      return Verdict.new(:waiting, nil, nil) if sent.empty?

      started = sent.sum(&:played).positive?
      metric = started ? "started a game" : "clicked"
      counts = started ? :played : :clicked
      first, second = sent.sort_by { |row| [ -share(row, counts), row.rank_key ] }.first(2)
      leader = first if second.nil? ? share(first, counts).positive? : share(first, counts) > share(second, counts)
      return Verdict.new(:early, leader, metric) if early?(sent)

      Verdict.new(leader && z(first, second, counts) >= CLEAR_Z ? :clear : :close, leader, metric)
    end

    # [ [answer label, people] ] from The Pick's tracked links, most picked first.
    def pick_answers
      row = rows.find { |candidate| candidate.style == "pick" }
      clicks = row ? Analytics.new(broadcast: row.broadcast).by_link.to_h { |key, people, _| [ key, people ] } : {}
      CyvasseFour::PICK_ANSWERS.map { |key, (label, _)| [ label, clicks.fetch(key, 0) ] }.sort_by { |label, people| [ -people, label ] }
    end

    private

    def row(style)
      broadcast = Broadcast.find_by(slug: "#{CyvasseFour::SLUG_PREFIX}#{style}")
      return unless broadcast

      Row.new(style, "The #{style.titleize}", broadcast, Analytics.new(broadcast: broadcast).summary,
              StagedEmail.where(broadcast: broadcast, status: %w[staged approved]).count)
    end

    def early?(sent)
      sent.size < CyvasseFour::STYLES.size || sent.any? { |row| row.summary.base < MIN_DELIVERED }
    end

    # Reader counts run over every sent email while the base can be delivered,
    # so a count is capped at its base when Resend's reports lag.
    def hits(row, counts) = [ row.public_send(counts), row.summary.base ].min

    def share(row, counts)
      row.summary.base.zero? ? 0.0 : hits(row, counts).to_f / row.summary.base
    end

    # The two-proportion z-score of first over second, pooled.
    def z(first, second, counts)
      a = first.summary.base
      b = second.summary.base
      pooled = (hits(first, counts) + hits(second, counts)).to_f / (a + b)
      error = Math.sqrt(pooled * (1 - pooled) * ((1.0 / a) + (1.0 / b)))
      error.zero? ? 0.0 : (share(first, counts) - share(second, counts)) / error
    end
  end
end

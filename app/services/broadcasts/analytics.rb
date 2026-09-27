module Broadcasts
  # The numbers behind the email analytics dashboard (/broadcasts/analytics,
  # task email-analytics-dashboard), read from the delivery rollups and the
  # event log (task email-event-log-webhooks). Everything is an SQL aggregate,
  # so it stays quick at the Cyvasse list's size (~19k deliveries).
  #
  # Counting rules, so the numbers mean one thing:
  #   - a rate's base is the deliveries SENT (sent_at set), except complaints
  #     and engagement, whose base is DELIVERED when Resend has reported
  #     deliveries and SENT until it has;
  #   - opens and clicks count PEOPLE: deliveries with a human open or click
  #     (EmailEvents::MachineDetector), with machine-only ones shown apart;
  #   - Resend's own open, click and sent reports never add to a count (our
  #     pixel, redirect and sender are the counters);
  #   - a result (event kind "converted", data goal) counts each email once
  #     per goal.
  class Analytics
    # Resend suspends sending above these (docs: account quotas and limits);
    # the dashboard turns amber at WARN and red at LIMIT.
    BOUNCE = { warn: 0.02, limit: 0.04 }.freeze
    COMPLAINT = { warn: 0.0005, limit: 0.0008 }.freeze

    PROVIDERS = {
      "Gmail" => %w[gmail.com googlemail.com],
      "Microsoft" => %w[hotmail.com outlook.com live.com msn.com windowslive.com hotmail.co.uk hotmail.fr live.co.uk],
      "Yahoo / AOL" => %w[yahoo.com ymail.com aol.com yahoo.co.uk yahoo.fr yahoo.com.br],
      "Apple" => %w[icloud.com me.com mac.com]
    }.freeze

    GOALS = %w[signed_in played_match joined_newsletter requested_app].freeze

    Summary = Data.define(:sent, :delivered, :hard_bounced, :soft_bounced, :complained, :unsubscribed,
                          :human_opened, :machine_only_opened, :human_clicked, :machine_only_clicked, :results) do
      def bounced = hard_bounced + soft_bounced
      def base = delivered.positive? ? delivered : sent
      def bounce_rate = rate(bounced, sent)
      def complaint_rate = rate(complained, base)
      def unsubscribe_rate = rate(unsubscribed, base)
      def open_rate = rate(human_opened, base)
      def click_rate = rate(human_clicked, base)
      def click_to_open_rate = rate(human_clicked, human_opened)
      def result_rate(goal) = rate(results.fetch(goal, 0), base)

      def rate(part, whole) = whole.to_i.zero? ? nil : part.to_f / whole
    end

    def initialize(broadcast: nil)
      @broadcast = broadcast
    end

    def deliveries
      scope = BroadcastDelivery.where.not(sent_at: nil)
      @broadcast ? scope.where(broadcast: @broadcast) : scope
    end

    COLUMNS = [
      "COUNT(*)",
      "COUNT(broadcast_deliveries.delivered_at)",
      "COUNT(*) FILTER (WHERE broadcast_deliveries.bounced_at IS NOT NULL AND broadcast_deliveries.bounce_kind = 'hard')",
      "COUNT(*) FILTER (WHERE broadcast_deliveries.bounced_at IS NOT NULL AND COALESCE(broadcast_deliveries.bounce_kind, '') <> 'hard')",
      "COUNT(broadcast_deliveries.complained_at)",
      "COUNT(broadcast_deliveries.unsubscribed_at)",
      "COUNT(broadcast_deliveries.human_opened_at)",
      "COUNT(*) FILTER (WHERE broadcast_deliveries.opened_at IS NOT NULL AND broadcast_deliveries.human_opened_at IS NULL)",
      "COUNT(broadcast_deliveries.human_clicked_at)",
      "COUNT(*) FILTER (WHERE broadcast_deliveries.clicked_at IS NOT NULL AND broadcast_deliveries.human_clicked_at IS NULL)"
    ].map { |sql| Arel.sql(sql) }.freeze

    def summary(scope = deliveries)
      counts = scope.pick(*COLUMNS).map(&:to_i)
      Summary.new(*counts, results(scope))
    end

    # Results per goal: distinct emails that reached it.
    def results(scope = deliveries)
      counts = EmailEvent.where(kind: "converted", broadcast_delivery_id: scope.select(:id))
                         .group(Arel.sql("data->>'goal'"))
                         .distinct.count(:broadcast_delivery_id)
      GOALS.index_with { |goal| counts.fetch(goal, 0) }
    end

    # [ [broadcast, summary] ] newest first, for every broadcast with a send.
    def by_broadcast
      Broadcast.where(id: BroadcastDelivery.where.not(sent_at: nil).select(:broadcast_id)).recent.map do |broadcast|
        [ broadcast, summary(deliveries.where(broadcast: broadcast)) ]
      end
    end

    # [ [date, summary] ] by the (UTC) day the email was sent, newest first. Stands
    # in for waves until the sender sends in waves.
    def by_send_day
      days = deliveries.pluck(Arel.sql("DISTINCT DATE(broadcast_deliveries.sent_at)")).compact.sort.reverse
      days.map { |day| [ day, summary(deliveries.where(sent_at: Time.utc(day.year, day.month, day.day).all_day)) ] }
    end

    # [ [provider, summary] ] by the recipient's mailbox provider, biggest first.
    def by_provider
      domain = "split_part(lower(contacts.email), '@', 2)"
      buckets = PROVIDERS.transform_values { |domains| deliveries.joins(:contact).where("#{domain} IN (?)", domains) }
      buckets["Other"] = deliveries.joins(:contact).where("#{domain} NOT IN (?)", PROVIDERS.values.flatten)
      buckets.map { |name, scope| [ name, summary(scope) ] }
             .reject { |_, s| s.sent.zero? }
             .sort_by { |_, s| -s.sent }
    end

    # [ [link_key, people, machines] ] from our click redirect, most clicked first.
    def by_link
      rows = EmailEvent.where(kind: "clicked", source: "redirect", broadcast_delivery_id: deliveries.select(:id))
                       .group(:link_key, :machine).distinct.count(:broadcast_delivery_id)
      rows.each_with_object(Hash.new { |h, k| h[k] = [ 0, 0 ] }) do |((key, machine), count), out|
        out[key.presence || "(unknown)"][machine ? 1 : 0] += count
      end.map { |key, (people, machines)| [ key, people, machines ] }
          .sort_by { |key, people, machines| [ -people, -machines, key ] }
    end

    # The list as it stands, whatever was sent.
    def list_health
      {
        total: Contact.count,
        subscribed: Contact.subscribed.count,
        unsubscribed: Contact.where(subscribed: false).group(Arel.sql("COALESCE(unsubscribe_reason, 'requested')")).count
      }
    end

    # :green, :amber or :red for a rate against its limits; :none before any send.
    def self.health(rate, limits)
      return :none if rate.nil?
      return :red if rate >= limits[:limit]
      return :amber if rate >= limits[:warn]

      :green
    end
  end
end

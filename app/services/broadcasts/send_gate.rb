# Whether staged broadcast email may go out now, and how much (task
# staged-email-queue). Two checks, both over the last 24 hours and across every
# broadcast, because sender reputation is the domain's, not one campaign's:
#
#   daily cap   at most DAILY_CAP emails sent or queued to send
#   reputation  pause when bounces pass 2% of sends, or complaints pass 0.05%
#
# The reputation check is a first stub read straight from EmailEvent. Mailbox
# providers start throttling a sender near these rates, so crossing either one
# stops Broadcast#execute_staged! until a person looks.
module Broadcasts
  class SendGate
    DAILY_CAP = 500
    WINDOW = 24.hours
    MAX_BOUNCE_RATE = 0.02
    MAX_COMPLAINT_RATE = 0.0005

    # delivered: sent in the window; queued: handed to the send job, not yet
    # sent. Rates are over delivered, the sends a bounce can answer.
    Status = Data.define(:delivered, :queued, :daily_cap, :bounces, :complaints, :reasons) do
      def sent = delivered + queued
      def paused? = reasons.any?
      def remaining = paused? ? 0 : [ daily_cap - sent, 0 ].max
      def bounce_rate = delivered.zero? ? 0.0 : bounces.to_f / delivered
      def complaint_rate = delivered.zero? ? 0.0 : complaints.to_f / delivered
    end

    def self.status(**) = new(**).status

    def initialize(now: Time.current, daily_cap: DAILY_CAP)
      @now = now
      @daily_cap = daily_cap
    end

    def status
      since = @now - WINDOW
      delivered = BroadcastDelivery.where(sent_at: since..).count
      # Queued but not yet sent: a second execute before the jobs run must not
      # take the cap twice.
      queued = StagedEmail.where(status: "approved", sent_at: nil, queued_at: since..).count
      events = EmailEvent.where(occurred_at: since..)
      bounces = events.of_kind("bounced").count
      complaints = events.of_kind("complained").count

      status = Status.new(delivered: delivered, queued: queued, daily_cap: @daily_cap,
                          bounces: bounces, complaints: complaints, reasons: [])
      reasons = []
      reasons << format("bounce rate %.1f%% is over 2%%", 100 * status.bounce_rate) if status.bounce_rate > MAX_BOUNCE_RATE
      reasons << format("complaint rate %.2f%% is over 0.05%%", 100 * status.complaint_rate) if status.complaint_rate > MAX_COMPLAINT_RATE
      reasons << "daily cap of #{@daily_cap} reached" if status.sent >= @daily_cap
      status.with(reasons: reasons)
    end
  end
end

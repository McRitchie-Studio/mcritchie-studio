module AgentMessages
  # Our own cap on Discord Gateway IDENTIFYs, far under Discord's. Discord allows
  # about 1,000 session starts per bot token per day and RESETS THE TOKEN past
  # that, which would take the whole agent mailbox down until a human files a
  # new one. A listener that crash-loops before READY would otherwise IDENTIFY
  # once per backoff, all day.
  #
  # The window is ROLLING (the last WINDOW) and PERSISTED, because the loop it
  # guards is exactly the one that restarts the process: the Solid Queue
  # supervisor re-runs the scheduler's start hook when the scheduler dies, so an
  # in-memory count would reset on every crash. It lives on one
  # agent_message_cursors row (source_ref SOURCE_REF; the poll never reads it,
  # since it walks guild channels, not cursor rows): `cursor` holds the epoch
  # seconds of each IDENTIFY in the window, comma-separated, and `polled_at` the
  # last one. Only the leader-lock holder writes it.
  #
  # RESUME does not start a session, so it never spends from this budget.
  class GatewayIdentifyBudget
    LIMIT = 200
    WINDOW = 24.hours
    SOURCE_REF = "discord-gateway:identify".freeze

    attr_reader :limit, :window

    def initialize(limit: LIMIT, window: WINDOW)
      @limit = limit
      @window = window
    end

    # IDENTIFYs sent inside the window ending at `now`.
    def spent(now = Time.current) = stamps(now).size

    def available?(now = Time.current) = spent(now) < @limit

    # When the next IDENTIFY is allowed: now while the budget has room, else
    # when the oldest one in the window rolls out.
    def next_at(now = Time.current)
      times = stamps(now)
      return now if times.size < @limit

      Time.zone.at(times.first(times.size - @limit + 1).last) + @window
    end

    # Records one IDENTIFY at `now`, pruning what has rolled out. Raises if the
    # write fails, so the caller can refuse to IDENTIFY unrecorded.
    def spend!(now = Time.current)
      row = cursor_row
      row.with_lock do
        kept = parse(row.cursor).select { |t| t > (now - @window).to_i }
        row.update!(cursor: (kept << now.to_i).join(","), polled_at: now)
      end
    end

    private

    def stamps(now)
      floor = (now - @window).to_i
      parse(cursor_row.cursor).select { |t| t > floor }.sort
    end

    def parse(value) = value.to_s.split(",").filter_map { |t| Integer(t, exception: false) }

    def cursor_row = AgentMessageCursor.for("discord", SOURCE_REF)
  end
end

require "socket"
require "openssl"
require "websocket/driver"

module AgentMessages
  # The PUSH half of the agent mailbox's inbound read: one Discord Gateway (v10)
  # websocket for the bot, feeding every MESSAGE_CREATE through the same
  # DiscordIngest the backstop poll uses, so the unique index dedupes the two
  # (docs/agents/system/agent-message-loop.md).
  #
  # WHERE IT RUNS. A thread inside the Solid Queue SCHEDULER process on the
  # existing worker dyno, started and stopped by its lifecycle hooks
  # (config/initializers/agent_message_gateway.rb). There is exactly one
  # scheduler per `bin/jobs` supervisor whatever JOB_CONCURRENCY says, it is
  # nearly idle (it only enqueues recurring jobs), the supervisor replaces it if
  # it dies (re-running the start hook), and its stop hook runs on SIGTERM. No new
  # dyno, no job thread pinned forever.
  #
  # ONE CONNECTION PER TOKEN. Before connecting, the thread takes
  # GatewayLeaderLock, a Postgres session advisory lock, on the one database
  # connection it leases for its whole life (its ingest writes use the same
  # one). A second process, or a dyno restart's overlap, waits for the lock and
  # retries every LOCK_RETRY seconds. While connected, the holder re-checks the
  # lock every LOCK_CHECK_EVERY seconds and stands down (closes the socket) the
  # moment its backend no longer holds it.
  #
  # The token is DISCORD_AGENT_BOT_TOKEN. Without it the listener is inert and
  # says so once. Neither the token nor an IDENTIFY/RESUME payload is ever logged.
  #
  # THE IDENTIFY BUDGET. Discord allows about 1,000 session starts (IDENTIFYs)
  # per token per day and resets the token past that. So the listener RESUMEs
  # whenever the session allows it, and before every IDENTIFY it checks two
  # counts: our own rolling, persisted GatewayIdentifyBudget (200 a day), and
  # Discord's session_start_limit (GatewayStartLimit, GET /gateway/bot), keeping
  # START_RESERVE starts in hand. Either spent: it stands down until the window
  # rolls (rechecking every BUDGET_RECHECK), with one ErrorLog receipt.
  #
  # THE HANDSHAKE DEADLINE. TCP and TLS must finish within HANDSHAKE_TIMEOUT,
  # then the websocket upgrade, HELLO and READY (or RESUMED) within another
  # HANDSHAKE_TIMEOUT (at most twice that in all), or the socket is closed
  # and the listener backs off: a stalled handshake never holds the leader lock
  # with no live listener behind it.
  #
  # A routine reconnect is a log line. A fatal close, a message it could not
  # store, a spent IDENTIFY budget, and the thread dying also write an ErrorLog
  # receipt.
  class DiscordGateway
    LOG = "[agent-messages] discord gateway".freeze
    # Seconds between attempts to take the leader lock while another holds it.
    LOCK_RETRY = 30
    # Seconds between leader-lock checks while connected.
    LOCK_CHECK_EVERY = 15
    # Reconnect backoff in seconds, by consecutive failure. The count resets only
    # after a connection has stayed up STABLE_AFTER seconds past READY/RESUMED,
    # so a session that drops right after READY still climbs the ladder.
    BACKOFF = [ 1, 2, 5, 10, 30, 60, 120, 300 ].freeze
    STABLE_AFTER = 60
    # Seconds for TCP and TLS, then again from the upgrade to READY or RESUMED,
    # before the attempt is abandoned.
    HANDSHAKE_TIMEOUT = 30
    # Discord session starts kept in hand: below this many `remaining`, the
    # listener waits for Discord's reset_after instead of IDENTIFYing.
    START_RESERVE = 10
    # While standing down for a spent budget, recheck at least this often.
    BUDGET_RECHECK = 15 * 60
    # Seconds the stop hook waits for the thread to close the socket and unlock.
    STOP_JOIN = 5
    # Thread → parent channel ids remembered for overrides; cleared past this.
    THREAD_CACHE_LIMIT = 10_000
    DISABLE_ENV = "DISCORD_GATEWAY".freeze

    # What an ErrorLog receipt names when Discord refuses the connection for good.
    Fatal = Class.new(StandardError)
    # What an ErrorLog receipt names when the listener stands down to save IDENTIFYs.
    BudgetSpent = Class.new(StandardError)
    # TLS or the websocket handshake did not finish in time.
    HandshakeTimeout = Class.new(Timeout::Error)

    class << self
      attr_reader :instance

      # The scheduler's start hook. Starts the listener thread, or logs once why
      # it stays inert.
      def boot(logger: Rails.logger, env: ENV, routes: nil)
        routes ||= Routes.load
        reason = idle_reason(env, routes)
        if reason
          logger.info("#{LOG} idle: #{reason}; nothing is read over the gateway")
          return nil
        end

        @instance = new(token: DiscordBot.token, routes: routes, logger: logger).tap(&:start)
      end

      # The scheduler's stop hook.
      def shutdown
        @instance&.stop
        @instance = nil
      end

      def idle_reason(env, routes)
        return "#{DiscordBot::TOKEN_ENV} is unset" if env[DiscordBot::TOKEN_ENV].to_s.strip.empty?
        return "#{DISABLE_ENV}=off" if env[DISABLE_ENV].to_s.strip.casecmp?("off")
        return "config/agent_routes.yml lists no Discord guild" if routes.guild_ids.empty?

        nil
      end

      # The production connector: TLS to the gateway host, verified, with the
      # whole TCP connect and TLS handshake bounded by `timeout` seconds.
      def tls_connect(url, timeout: HANDSHAKE_TIMEOUT)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        uri = URI(url)
        tcp = ::Socket.tcp(uri.host, uri.port || 443, connect_timeout: [ timeout, 10 ].min)
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = uri.host
        ssl.sync_close = true
        tls_handshake(ssl, tcp, deadline, timeout)
        ssl
      rescue StandardError
        ssl ? ssl.close : tcp&.close
        raise
      end

      private

      def tls_handshake(ssl, io, deadline, timeout)
        loop do
          state = ssl.connect_nonblock(exception: false)
          return unless state == :wait_readable || state == :wait_writable

          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ready = left.positive? &&
                  (state == :wait_readable ? IO.select([ io ], nil, nil, left) : IO.select(nil, [ io ], nil, left))
          raise HandshakeTimeout, "TLS handshake did not finish within #{timeout}s" unless ready
        end
      end
    end

    attr_reader :session, :thread_parents

    # `connector` takes a wss URL and returns a connected, readable IO (the seam
    # tests replace with one end of a socket pair). `lock` is built on the
    # thread's leased connection unless a test hands one in.
    def initialize(token:, routes: Routes.load, logger: Rails.logger, connector: self.class.method(:tls_connect),
                   lock: nil, ingest: nil, lock_retry: LOCK_RETRY, lock_check_every: LOCK_CHECK_EVERY, backoff: BACKOFF,
                   budget: nil, start_limit: nil, handshake_timeout: HANDSHAKE_TIMEOUT)
      raise ArgumentError, "a bot token is required" if token.to_s.strip.empty?

      @token = token
      @routes = routes
      @logger = logger
      @connector = connector
      @lock = lock
      @ingest = ingest || DiscordIngest.new(routes: routes, logger: logger)
      @lock_retry = lock_retry
      @lock_check_every = lock_check_every
      @backoff = backoff
      @budget = budget || GatewayIdentifyBudget.new
      @start_limit = start_limit || GatewayStartLimit.new(token: token)
      @handshake_timeout = handshake_timeout
      @budget_receipted = false
      @ready_at = nil
      @session = GatewaySession.new
      @thread_parents = {}
      @failures = 0
      @stopping = false
      @wake_r, @wake_w = IO.pipe
    end

    def start
      @thread = Thread.new do
        Thread.current.name = "discord-gateway"
        Thread.current.report_on_exception = false
        run
      end
      self
    end

    def stop
      @stopping = true
      wake
      @thread&.join(STOP_JOIN)
    end

    def stopping? = @stopping

    def alive? = @thread&.alive? || false

    def run
      leased = @lock.nil?
      @lock ||= GatewayLeaderLock.new(key: GatewayLeaderLock.key_for(@token), connection: ActiveRecord::Base.lease_connection)
      announced_wait = false
      until stopping?
        unless @lock.held? || @lock.acquire
          @logger.info("#{LOG}: another process holds the connection; standing by") unless announced_wait
          announced_wait = true
          pause(@lock_retry)
          next
        end
        announced_wait = false

        # RESUME costs no session start; only an IDENTIFY is budgeted.
        unless @session.resumable?
          wait = identify_wait
          if wait
            pause(wait)
            next
          end
        end

        outcome = connect_once
        case outcome
        when :stopped then break
        when :fatal then break
        when :lost_lock
          @logger.info("#{LOG}: leader lock lost; standing down")
          @session.reset!
          @lock.release
          pause(@lock_retry)
        else
          @failures = 0 if @ready_at && now - @ready_at >= STABLE_AFTER
          @failures += 1
          pause(backoff)
        end
      end
    rescue StandardError => e
      @logger.error("#{LOG} stopped on #{e.class}: #{e.message.to_s[0, 200]}")
      receipt(e)
    ensure
      @lock&.release
      ActiveRecord::Base.connection_pool.release_connection if leased
    end

    # One connection, from the socket opening to its close. Returns :stopped,
    # :fatal, :lost_lock, :handshake_timeout, :resume or :identify.
    def connect_once
      url = @session.connect_url
      @socket = WebSocketClient.new(@connector.call(url), url, wake: @wake_r)
      @socket.on_text { |text| handle_frame(text) }
      @session.connection_opened!
      @pending = nil
      @next_heartbeat = nil
      @ready_at = nil
      @handshake_by = now + @handshake_timeout
      next_lock_check = now + @lock_check_every
      @socket.start

      loop do
        return finish(1000, :stopped) if stopping?
        return handshake_expired if @ready_at.nil? && now >= @handshake_by

        if now >= next_lock_check
          next_lock_check = now + @lock_check_every
          return finish(1000, :lost_lock) unless @lock.held?
        end
        return finish(GatewaySession::RESUME_CLOSE, @pending) if @pending

        if @next_heartbeat && now >= @next_heartbeat
          return finish(GatewaySession::RESUME_CLOSE, :resume) if @session.zombie?

          transmit(@session.heartbeat_payload)
          @next_heartbeat = now + (@session.heartbeat_interval / 1000.0)
        end

        @socket.pump(wait_for(next_lock_check))
        return closed_outcome if @socket.closed?
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError, Timeout::Error => e
      @logger.info("#{LOG}: connection dropped (#{e.class}); reconnecting")
      @socket&.close(nil)
      :resume
    rescue StandardError => e
      @logger.error("#{LOG}: connection failed on #{e.class}; reconnecting")
      @socket&.close(nil)
      :resume
    end

    # One text frame from Discord. Public so a test can drive the protocol.
    def handle_frame(text)
      payload = JSON.parse(text)
      return unless payload.is_a?(Hash)

      @session.receive(payload).each { |event, value| on_event(event, value) }
    rescue JSON::ParserError
      @logger.info("#{LOG}: ignored a frame that is not JSON")
    end

    private

    def on_event(event, value)
      case event
      when :hello
        opening = @session.opening_payload(@token)
        # Recorded BEFORE it is sent: a budget that cannot be written raises
        # here, and the attempt fails closed (no IDENTIFY, a backoff).
        @budget.spend!(Time.current) if opening[:op] == GatewaySession::IDENTIFY
        transmit(opening)
        interval = value.to_i.positive? ? value / 1000.0 : 41.25
        @next_heartbeat = now + (interval * rand) # Discord's jitter for the first beat
      when :heartbeat_now then transmit(@session.heartbeat_payload)
      when :reconnect then @pending ||= value
      when :ready
        @ready_at = now
        @logger.info("#{LOG}: connected")
      when :resumed
        @ready_at = now
        @logger.info("#{LOG}: resumed")
      when :message then ingest(value)
      when :guild then note_guild(value)
      when :threads then remember_threads(value)
      end
    end

    def ingest(data)
      guild_id = data["guild_id"].to_s
      return if guild_id.empty? # a direct message: not ours to read

      @ingest.call(data, guild_id: guild_id, parent_id: @thread_parents[data["channel_id"].to_s],
                         source: "discord-gateway")
    rescue StandardError => e
      # The backstop poll reads it again later; never log the content.
      @logger.error("#{LOG}: could not store message #{data['id']}: #{e.class}")
      receipt(e)
    end

    def note_guild(data)
      guild_id = data["id"].to_s
      return DiscordIngest.note_unlisted_guild(guild_id, logger: @logger) unless @routes.guild?(guild_id)

      remember_threads(Array(data["threads"]))
    end

    def remember_threads(threads)
      @thread_parents.clear if @thread_parents.size > THREAD_CACHE_LIMIT
      Array(threads).each do |thread|
        next unless thread.is_a?(Hash) && thread["parent_id"].present?

        @thread_parents[thread["id"].to_s] = thread["parent_id"].to_s
      end
    end

    # Never logged: an opening payload carries the token.
    def transmit(payload)
      @socket.text(JSON.generate(payload))
    end

    def closed_outcome
      outcome = @session.close_outcome(@socket.close_code)
      if outcome == :fatal
        line = "#{LOG}: Discord closed the connection with #{@socket.close_code}; not reconnecting " \
               "(check the token and the Message Content intent)"
        @logger.error(line)
        receipt(Fatal.new(line))
      else
        @logger.info("#{LOG}: closed with #{@socket.close_code}; reconnecting (#{outcome})")
      end
      outcome
    end

    # An ErrorLog row for the triage view. Never raises: the listener outlives a
    # database blip, and the log line above already said what happened.
    def receipt(error)
      ErrorLog.capture!(error)
    rescue StandardError
      nil
    end

    # nil when an IDENTIFY may go now; else the seconds to stand down first.
    # Our budget first (no network), then Discord's own count. A failure to read
    # either is a failed attempt: back off, never IDENTIFY blind.
    def identify_wait
      at = Time.current
      unless @budget.available?(at)
        resume_at = @budget.next_at(at)
        stand_down("IDENTIFY budget spent (#{@budget.limit} in #{@budget.window.inspect}); " \
                   "standing down until #{resume_at.utc.iso8601}")
        return (resume_at - at).clamp(1, BUDGET_RECHECK)
      end

      limit = @start_limit.call
      if limit.remaining < START_RESERVE
        stand_down("Discord session_start_limit has #{limit.remaining} of #{limit.total} left; " \
                   "standing down #{limit.reset_after.round}s for its reset")
        return (limit.reset_after + 1).clamp(1, BUDGET_RECHECK)
      end

      @budget_receipted = false
      @check_receipted = false
      nil
    rescue StandardError => e
      @logger.info("#{LOG}: could not check the IDENTIFY budget (#{e.class}); backing off")
      # One receipt per outage: a revoked token (401 here) never reaches the
      # IDENTIFY whose fatal close would otherwise be its only ErrorLog row.
      receipt(e) unless @check_receipted
      @check_receipted = true
      @failures += 1
      backoff
    end

    # One log line and one ErrorLog receipt per stand-down, however many
    # rechecks it takes for the window to roll.
    def stand_down(reason)
      return if @budget_receipted

      @budget_receipted = true
      line = "#{LOG}: #{reason}"
      @logger.error(line)
      receipt(BudgetSpent.new(line))
    end

    def handshake_expired
      @logger.info("#{LOG}: handshake did not finish within #{@handshake_timeout}s; closing and backing off")
      @socket.close(nil)
      :handshake_timeout
    end

    def finish(code, outcome)
      @socket.close(code)
      @session.reset! if code == 1000
      outcome
    end

    def wait_for(next_lock_check)
      deadlines = [ next_lock_check, @next_heartbeat, (@handshake_by if @ready_at.nil?) ].compact
      [ deadlines.min - now, 0.05 ].max
    end

    def backoff
      base = @backoff[[ @failures - 1, 0 ].max] || @backoff.last
      base * (0.5 + (rand / 2))
    end

    def pause(seconds)
      ready, = IO.select([ @wake_r ], nil, nil, seconds)
      drain_wake if ready
    end

    def wake
      @wake_w.write_nonblock(".", exception: false)
    rescue IOError
      nil
    end

    def drain_wake
      @wake_r.read_nonblock(64, exception: false)
    rescue IOError
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # A websocket CLIENT over any connected IO, framed by websocket-driver (the
    # gem Action Cable already ships). The driver writes through #write and reads
    # what #pump feeds it; this class never touches the payloads.
    class WebSocketClient
      READ_SIZE = 64 * 1024
      ABNORMAL = 1006

      attr_reader :url, :close_code

      def initialize(io, url, wake:)
        @io = io
        @url = url
        @wake = wake
        @closed = false
        @driver = ::WebSocket::Driver.client(self)
        @driver.on(:message) { |event| @on_text&.call(event.data) }
        @driver.on(:close) do |event|
          @close_code ||= event.code
          @closed = true
        end
      end

      def on_text(&block) = (@on_text = block)

      def start = @driver.start

      def text(string) = @driver.text(string)

      # Called by the driver with the bytes to send.
      def write(data) = @io.write(data)

      def closed? = @closed

      # Waits up to `timeout` seconds for bytes (or a wake), then feeds them to
      # the driver, which emits messages and the close.
      def pump(timeout)
        unless buffered?
          ready, = IO.select([ @io, @wake ], nil, nil, timeout)
          return if ready.nil? || !ready.include?(@io)
        end
        data = @io.read_nonblock(READ_SIZE, exception: false)
        case data
        when :wait_readable, :wait_writable then nil
        when nil then mark_closed(ABNORMAL)
        else @driver.parse(data)
        end
      end

      # Sends a close frame with `code` (nil sends none) and drops the socket.
      def close(code)
        @driver.close(nil, code) if code && !@closed
      rescue StandardError
        nil
      ensure
        mark_closed(code || ABNORMAL)
        begin
          @io.close
        rescue StandardError
          nil
        end
      end

      private

      def mark_closed(code)
        @close_code ||= code
        @closed = true
      end

      def buffered? = @io.respond_to?(:pending) && @io.pending.to_i.positive?
    end
  end
end

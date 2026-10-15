module AgentMessages
  # The Discord Gateway (v10) protocol state for ONE bot session, with no I/O:
  # it reads decoded payloads and close codes and answers with what to send and
  # what to do. AgentMessages::DiscordGateway owns the socket and acts on it.
  #
  # The state that outlives a connection is what RESUME needs: the session id,
  # the last sequence number, and the resume_gateway_url READY named. A resumed
  # session replays the events missed while disconnected; a session Discord
  # invalidated (op 9 false, close 4007/4009) starts over with IDENTIFY.
  #
  # The token goes into IDENTIFY and RESUME payloads only. Nothing here logs, and
  # the caller must never log an opening payload.
  class GatewaySession
    DEFAULT_URL = "wss://gateway.discord.gg".freeze
    QUERY = "/?v=10&encoding=json".freeze

    # Intents: GUILDS (1 << 0) for guild, channel and thread events,
    # GUILD_MESSAGES (1 << 9) for MESSAGE_CREATE, and the privileged
    # MESSAGE_CONTENT (1 << 15) so a message carries its text.
    INTENTS = (1 << 0) | (1 << 9) | (1 << 15)

    # Opcodes.
    DISPATCH = 0
    HEARTBEAT = 1
    IDENTIFY = 2
    RESUME = 6
    RECONNECT = 7
    INVALID_SESSION = 9
    HELLO = 10
    HEARTBEAT_ACK = 11

    # Close codes after which reconnecting cannot help: authentication failed,
    # invalid shard, sharding required, invalid API version, invalid or
    # disallowed intents. The listener stops and logs the code.
    FATAL_CLOSES = [ 4004, 4010, 4011, 4012, 4013, 4014 ].freeze
    # Close codes that end the session itself: invalid seq, session timed out.
    # Reconnect, but IDENTIFY afresh.
    FRESH_CLOSES = [ 4007, 4009 ].freeze
    # The code the listener closes with when it means to RESUME. A 1000 or 1001
    # close invalidates the session on Discord's side.
    RESUME_CLOSE = 4000

    attr_reader :seq, :session_id, :resume_url, :heartbeat_interval, :bot_user_id

    def initialize
      reset!
    end

    # Forget the session: the next connection IDENTIFYs.
    def reset!
      @seq = nil
      @session_id = nil
      @resume_url = nil
      @awaiting_ack = false
      @heartbeat_interval = nil
    end

    def resumable? = @session_id.present? && !@seq.nil?

    # Where to connect: the resume URL READY named when resuming, else the
    # default gateway.
    def connect_url
      base = resumable? && @resume_url.present? ? @resume_url : DEFAULT_URL
      "#{base.delete_suffix('/')}#{QUERY}"
    end

    # The first payload after HELLO: RESUME when the session can be resumed,
    # else IDENTIFY. It carries the token; never log it.
    def opening_payload(token)
      if resumable?
        { op: RESUME, d: { token: token, session_id: @session_id, seq: @seq } }
      else
        { op: IDENTIFY, d: { token: token, intents: INTENTS,
                             properties: { os: "linux", browser: "mcritchie-studio", device: "mcritchie-studio" } } }
      end
    end

    # A heartbeat to send now. It expects an ACK before the next one.
    def heartbeat_payload
      @awaiting_ack = true
      { op: HEARTBEAT, d: @seq }
    end

    # True when the previous heartbeat was never acknowledged: the connection is
    # a zombie, so close it and resume.
    def zombie? = @awaiting_ack

    # A new connection starts with no heartbeat in flight.
    def connection_opened! = (@awaiting_ack = false)

    # Reads one decoded payload. Returns a list of [event, value] pairs:
    #   [:hello, interval_ms]     send the opening payload, start heartbeating
    #   [:heartbeat_now, nil]     Discord asked for a heartbeat at once
    #   [:reconnect, :resume]     close and reconnect, then RESUME
    #   [:reconnect, :identify]   close and reconnect, then IDENTIFY
    #   [:ready, session_id]      a new session
    #   [:resumed, nil]           the session was resumed
    #   [:message, data]          a MESSAGE_CREATE
    #   [:guild, data]            a GUILD_CREATE (its threads included)
    #   [:threads, [thread...]]   THREAD_CREATE / THREAD_UPDATE / THREAD_LIST_SYNC
    def receive(payload)
      op = payload["op"]
      data = payload["d"]
      case op
      when HELLO
        @heartbeat_interval = data.is_a?(Hash) ? data["heartbeat_interval"].to_i : nil
        [ [ :hello, @heartbeat_interval ] ]
      when HEARTBEAT_ACK
        @awaiting_ack = false
        []
      when HEARTBEAT
        [ [ :heartbeat_now, nil ] ]
      when RECONNECT
        [ [ :reconnect, :resume ] ]
      when INVALID_SESSION
        reset! unless data == true
        [ [ :reconnect, data == true ? :resume : :identify ] ]
      when DISPATCH
        @seq = payload["s"] unless payload["s"].nil?
        dispatch(payload["t"], data)
      else
        []
      end
    end

    # What a close code means: :fatal (stop), :identify (session gone), or
    # :resume (reconnect and resume). The session is forgotten for :identify.
    def close_outcome(code)
      code = code.to_i
      return :fatal if FATAL_CLOSES.include?(code)

      if FRESH_CLOSES.include?(code)
        reset!
        return :identify
      end
      :resume
    end

    private

    def dispatch(type, data)
      data = {} unless data.is_a?(Hash)
      case type
      when "READY"
        @session_id = data["session_id"].to_s.presence
        @resume_url = data["resume_gateway_url"].to_s.presence
        @bot_user_id = data.dig("user", "id").to_s.presence
        [ [ :ready, @session_id ] ]
      when "RESUMED" then [ [ :resumed, nil ] ]
      when "MESSAGE_CREATE" then [ [ :message, data ] ]
      when "GUILD_CREATE" then [ [ :guild, data ] ]
      when "THREAD_CREATE", "THREAD_UPDATE" then [ [ :threads, [ data ] ] ]
      when "THREAD_LIST_SYNC" then [ [ :threads, Array(data["threads"]) ] ]
      else []
      end
    end
  end
end

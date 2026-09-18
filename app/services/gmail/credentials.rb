require "json"

module Gmail
  # Where the Gmail OAuth credential comes from, and the one place that knows.
  #
  # Shaped after Slack::Credentials in mcritchie-industries, with one
  # deliberate difference: Gmail needs THREE values (client id, client secret,
  # refresh token), and they live in ONE 1Password field as a JSON object
  # rather than three fields. `op read` is one call per field path and the
  # service account's daily quota is account-wide and shared by every lane, so
  # three fields would mean three quota hits on every pull for no gain.
  #
  # Two sources, in priority order:
  #   ENV["GMAIL_OAUTH_CREDENTIAL"] — Heroku, CI, and any non-interactive lane.
  #   1Password                     — the local desk, read through `op` so the
  #                                   secret never lands in a dotfile, a log,
  #                                   or a transcript.
  #
  # ABSENT and MALFORMED are different answers on purpose. Absent returns nil
  # and the ingest skips politely, because a desk without `op` installed must
  # still boot and run the rest of the suite. Malformed RAISES, because a value
  # that exists and cannot be used is a broken credential, and the one thing
  # this must never do is dress a filing mistake as an empty mailbox.
  module Credentials
    ITEM = "op://studio-agents/gmail.studio.agents/credential".freeze

    # The three keys the item's JSON must carry. Filed EMPTY until the real
    # values exist — a placeholder would make .configured? true and send the
    # job at Google for an invalid_grant, which reads as "revoked" rather than
    # "never filled in".
    REQUIRED_KEYS = %w[client_id client_secret refresh_token].freeze

    # `op` blocks for biometric unlock when the session is cold. Fine at a desk
    # and fatal in a cron dyno, so the read is bounded and a timeout degrades to
    # "no credential" instead of hanging the job.
    OP_TIMEOUT_SECONDS = 15

    # The value is present but unusable — bad JSON, or missing a key. Loud by
    # design; see the module comment.
    class Malformed < StandardError; end

    class << self
      def credential
        parse(raw_credential)
      end

      def configured?
        raw_credential.present?
      end

      def client_id     = credential&.fetch("client_id")
      def client_secret = credential&.fetch("client_secret")
      def refresh_token = credential&.fetch("refresh_token")

      # Which source answered — for operator output, so "no messages pulled" is
      # never ambiguous about whether it was a quiet mailbox or no credential.
      def source
        return "env" if env_credential
        return "1password" if op_credential
        nil
      end

      def reset!
        @op_credential = nil
        @op_read = false
      end

      # Injected in tests. Production shells out to `op`; the suite swaps in a
      # lambda, which keeps the double hand-rolled and matches how
      # Slack::Credentials takes its reader rather than reaching for a mocking
      # library.
      attr_writer :op_reader

      def op_reader
        @op_reader ||= method(:shell_read_from_op)
      end

      private

      def raw_credential
        env_credential || op_credential
      end

      def env_credential
        ENV["GMAIL_OAUTH_CREDENTIAL"].presence
      end

      def op_credential
        return @op_credential if @op_read

        @op_read = true
        @op_credential = op_reader.call(ITEM)
      end

      def parse(raw)
        return nil if raw.blank?

        parsed = JSON.parse(raw)
        unless parsed.is_a?(Hash)
          # The likeliest misfiling by a mile: the bare refresh token pasted in
          # where the object belongs. ("1//abc" even parses — as the number 1
          # with a comment — so the shape check, not the parse, is what catches
          # it, and the message has to say what the field wants instead.)
          raise Malformed, "#{ITEM} must hold a JSON object with " \
                           "#{REQUIRED_KEYS.join(', ')} — got #{parsed.class}. " \
                           "A bare token pasted into the field looks like this."
        end

        missing = REQUIRED_KEYS.reject { |key| parsed[key].to_s.strip.present? }
        if missing.any?
          raise Malformed, "#{ITEM} is missing #{missing.join(', ')} — file the " \
                           "full {client_id, client_secret, refresh_token} object"
        end

        parsed.slice(*REQUIRED_KEYS).transform_values { |value| value.to_s.strip }
      rescue JSON::ParserError => e
        # NEVER interpolate e.message: it echoes the input from the failure
        # point to end of stream, so a paste broken INSIDE a value carries live
        # token bytes — and this lands in ErrorLog, which stores .message
        # verbatim into Postgres and forwards it to Sentry. Position only.
        raise Malformed, "#{ITEM} is not valid JSON (#{e.message[/at line \d+ column \d+/] || 'position unreported'}) " \
                         "— re-copy the object from bin/gmail-oauth-mint; a pasted line break inside a value is the usual cause"
      end

      # Bounded on purpose — Open3.capture3 has no timeout of its own, so the
      # deadline is enforced here by killing the process. OP_TIMEOUT_SECONDS is
      # a real bound, not a comment.
      def shell_read_from_op(item)
        require "open3"
        out = nil
        Open3.popen3("op", "read", item) do |stdin, stdout, stderr, thread|
          stdin.close
          if thread.join(OP_TIMEOUT_SECONDS).nil?
            Process.kill("KILL", thread.pid) rescue nil
            thread.join
            return nil
          end
          out = stdout.read
          stderr.read
          return nil unless thread.value.success?
        end
        out.to_s.strip.presence
      rescue Errno::ENOENT, Errno::ESRCH, SystemCallError, IOError
        # `op` absent or unreachable — not an error, just an unconfigured desk.
        nil
      end
    end
  end
end

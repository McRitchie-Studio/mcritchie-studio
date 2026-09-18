require "json"
require "stringio"

module Workspace
  # Where the Google service-account credential comes from, and the one place
  # that knows. Shaped after Gmail::Credentials in this same repo — same source
  # precedence, same injectable reader, same bounded `op` read — so the two read
  # the same way to anyone who has read either.
  #
  # TWO GMAIL LANES LIVE IN THIS APP AND THEY ARE NOT INTERCHANGEABLE:
  #
  #   Gmail::*      an OAuth refresh token for alex@mcritchie.studio, scope
  #                 gmail.readonly ONLY, feeding DeskCaptureItem. It cannot
  #                 draft and cannot write.
  #   Workspace::*  this one — a service account impersonating the address the
  #                 Drive folders are shared with, holding four scopes including
  #                 gmail.compose, feeding the communications record and the
  #                 drafting pipeline.
  #
  # Do not collapse them without a decision: they differ in identity, in reach,
  # and in what a leak of either would cost.
  #
  # Two sources, in priority order:
  #   ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] — Heroku, CI, and any non-interactive lane.
  #   1Password                          — the local desk, read through `op` so
  #                                        the key never lands in a dotfile, a
  #                                        log, or a transcript.
  #
  # ABSENT and MALFORMED are different answers on purpose. Absent returns nil
  # and callers skip politely, because a desk without `op` must still boot and
  # run the rest of the suite. Malformed RAISES, because a key that exists and
  # cannot be used is a broken credential, and the one thing this must never do
  # is dress a filing mistake as an empty Drive.
  module Credentials
    ITEM = "op://industries-agents/google.drive.agents/credential".freeze

    # WHOSE MAILBOX AND DRIVE THIS ACTS AS. Pinned to a constant rather than
    # passed in, because domain-wide delegation cannot be narrowed at the grant:
    # it authorizes impersonation of ANY user in the domain and the CALLING CODE
    # picks the subject via the JWT `sub` claim. With the subject a constant, a
    # change of subject is a visible diff with a test to break; with it an
    # argument, it is a caller's typo away from reading someone else's mailbox.
    SUBJECT = "team@mcritchie.industries".freeze

    # The whole grant, frozen, asserted by the suite. Deliberately NOT the full
    # `drive` scope.
    #
    # `drive.file` is load-bearing beyond least-privilege: Google documents it
    # as covering only files the app CREATED, or that a user handed the app
    # through the Google Picker. A service account under domain-wide delegation
    # has no Picker interaction — so it can only ever write to files we made.
    # That is what puts "never edit a file we do not own" in the API layer
    # instead of in our own good intentions, and it is why a write path must
    # copy into a folder the subject owns before it edits.
    SCOPES = [
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/drive.file",
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.compose"
    ].freeze

    # Keys a usable service-account key must carry. `client_email` and
    # `private_key` are what the JWT assertion is built from; `type` is what
    # distinguishes a service-account key from an OAuth client secret, which is
    # the likeliest wrong file to paste into the field.
    REQUIRED_KEYS = %w[type client_email private_key].freeze
    SERVICE_ACCOUNT_TYPE = "service_account".freeze

    # `op` blocks for biometric unlock when the session is cold. Fine at a desk
    # and fatal in a cron dyno, so the read is bounded and a timeout degrades to
    # "no credential" instead of hanging the job.
    OP_TIMEOUT_SECONDS = 15

    # The value is present but unusable — bad JSON, wrong kind of key, or a
    # missing field. Loud by design.
    class Malformed < StandardError; end

    class << self
      def credential
        parse(raw_credential)
      end

      def configured?
        raw_credential.present?
      end

      # Which source answered — for operator output, so "nothing came back" is
      # never ambiguous between an empty Drive and no credential.
      def source
        return "env" if env_credential
        return "1password" if op_credential

        nil
      end

      # The authorizer both clients hand to their service object, impersonating
      # SUBJECT.
      #
      # `sub` is assigned AFTER make_creds, and BOTH ways of getting this wrong
      # are silent — which is the whole reason #subject exists and is asserted.
      #
      #   Passing `sub:` to make_creds does NOT raise. It prints
      #   "Unrecognized option(s) for ServiceAccountCredentials.make_creds: :sub"
      #   to stderr and DROPS it (measured 2026-09-17), handing back a
      #   credential with sub nil that looks correctly built.
      #
      #   Omitting the assignment does not raise either: the credential then
      #   authenticates as the service account ITSELF, which owns no mail and an
      #   empty Drive — so every call succeeds and returns nothing.
      #
      # A warning on stderr in a cron dyno is not a failure anyone sees, so the
      # subject is read back off the built object by a test instead.
      def authorizer
        @authorizer ||= begin
          require "googleauth"

          creds = ::Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(credential.to_json),
            scope: SCOPES
          )
          creds.sub = SUBJECT
          creds
        end
      end

      # The subject the authorizer will actually impersonate. Read back off the
      # built object rather than returning the constant, so the test proves the
      # assignment happened instead of proving the constant exists.
      def subject
        authorizer.sub
      end

      def reset!
        @op_credential = nil
        @op_read = false
        @authorizer = nil
      end

      # Injected in tests. Production shells out to `op`; the suite swaps in a
      # lambda (armed for the whole suite in test/test_helper.rb, alongside a
      # fake `op` on PATH that fails any test which reaches the real CLI).
      attr_writer :op_reader

      def op_reader
        @op_reader ||= method(:shell_read_from_op)
      end

      private

      def raw_credential
        env_credential || op_credential
      end

      def env_credential
        ENV["GOOGLE_SERVICE_ACCOUNT_JSON"].presence
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
          raise Malformed, "#{ITEM} must hold a service-account JSON key object, got #{parsed.class}"
        end

        missing = REQUIRED_KEYS.reject { |key| parsed[key].to_s.strip.present? }
        raise Malformed, "#{ITEM} is missing #{missing.join(', ')}" if missing.any?

        unless parsed["type"] == SERVICE_ACCOUNT_TYPE
          # An OAuth client secret is the wrong file and reads as plausible JSON,
          # so name what was found rather than failing later inside googleauth.
          raise Malformed, "#{ITEM} has type #{parsed['type'].inspect}, expected " \
                           "#{SERVICE_ACCOUNT_TYPE.inspect} — this looks like the wrong JSON file"
        end

        parsed
      rescue JSON::ParserError => e
        # NEVER interpolate e.message: it echoes the input from the failure point
        # to end of stream, so a key pasted with literal newlines inside
        # private_key carries the WHOLE key body into the message (and into
        # ErrorLog / Sentry). Position only — the rule Gmail::Credentials learned.
        raise Malformed, "#{ITEM} is not valid JSON (#{e.message[/at line \d+ column \d+/] || 'position unreported'}) " \
                         "— a literal line break inside private_key is the usual cause"
      end

      # Bounded on purpose — Open3.capture3 has no timeout of its own, so the
      # deadline is enforced here by killing the process.
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

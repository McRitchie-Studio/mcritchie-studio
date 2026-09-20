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
    # Named by the credential-filing convention, <service>.<entity>.<lane>:
    # google.industries.agents. The first draft of this constant said
    # google.drive.agents, but "drive" is not an entity, and a NEW item follows the
    # convention rather than being grandfathered in.
    ITEM = "op://industries-agents/google.industries.agents/credential".freeze

    # WHOSE MAILBOX AND DRIVE THIS ACTS AS — and why it is a table, not an
    # argument.
    #
    # Domain-wide delegation cannot be narrowed at the grant: it authorizes
    # impersonation of ANY user in a domain, and the CALLING CODE picks the
    # subject via the JWT `sub` claim. This used to be held by pinning one
    # address in a frozen constant. Multi-tenant access made that impossible —
    # there is a subject per workspace now — so the guard moved rather than
    # being dropped: #authorizer_for REFUSES any subject that is not an ACTIVE
    # WorkspaceAccount. A typo reaches nothing, and the set of domains this
    # system can open is one query.
    #
    # Refused because the subject is not on the allow-list. Distinct from a
    # Google refusal, which means the grant itself is missing.
    class UnregisteredSubject < StandardError; end

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

      # The authorizer a client hands to its service object, impersonating ONE
      # registered, active workspace subject.
      #
      # `sub` is assigned AFTER make_creds, and BOTH ways of getting this wrong
      # are silent — which is why #probe reads the subject back off the built
      # object rather than trusting it.
      #
      #   Passing `sub:` to make_creds does NOT raise. It prints
      #   "Unrecognized option(s) for ServiceAccountCredentials.make_creds: :sub"
      #   to stderr and DROPS it (measured 2026-09-17), handing back a
      #   credential with sub nil that looks correctly built.
      #
      #   Omitting the assignment does not raise either: the credential then
      #   authenticates as the service account ITSELF, which owns no mail and an
      #   empty Drive — so every call succeeds and returns nothing.
      def authorizer_for(subject)
        subject = normalize_subject(subject)
        unless WorkspaceAccount.impersonatable?(subject)
          raise UnregisteredSubject,
                "refusing to impersonate #{subject}: it is not an ACTIVE workspace_account. " \
                "Register the workspace, have its super-admin grant delegation, then run " \
                "bin/rails 'workspace:check[<domain>]' to prove it."
        end

        build_authorizer(subject)
      end

      # Proves a grant WITHOUT handing back anything that can read data.
      #
      # The allow-list cannot apply here: a workspace is pending precisely
      # because it cannot be impersonated yet, so the check that proves the
      # grant has to be allowed to try. What keeps this from being a hole is
      # that it (a) still requires the subject to be a REGISTERED row, so it
      # cannot sweep a domain for reachable users, and (b) returns a verdict,
      # never an authorizer — nothing can use it to fetch mail.
      #
      # Returns [ok, error_slug_or_nil].
      def probe(subject)
        subject = normalize_subject(subject)
        raise UnregisteredSubject, "#{subject} is not a registered workspace_account" unless
          WorkspaceAccount.exists?(subject: subject)

        # The rescue wraps ONLY the token fetch. Wrapping the whole method
        # swallowed the guard above and turned a refusal into a return value —
        # an UnregisteredSubject is a StandardError too.
        begin
          creds = build_authorizer(subject)
          creds.fetch_access_token!
          # Read the subject back off the BUILT object: a dropped assignment
          # would otherwise authenticate as the service account itself and look
          # perfectly fine.
          return [ false, "subject was not applied to the credential" ] unless creds.sub == subject

          [ true, nil ]
        rescue StandardError => e
          [ false, e.message.to_s[/"error":\s*"([^"]+)"/, 1] || e.class.to_s ]
        end
      end

      def reset!
        @op_credential = nil
        @op_read = false
        @authorizers = nil
      end

      # Injected in tests. Production shells out to `op`; the suite swaps in a
      # lambda (armed for the whole suite in test/test_helper.rb, alongside a
      # fake `op` on PATH that fails any test which reaches the real CLI).
      attr_writer :op_reader

      def op_reader
        @op_reader ||= method(:shell_read_from_op)
      end

      private

      def normalize_subject(subject) = subject.to_s.strip.downcase

      # Cached per subject: one credential object per workspace, each holding
      # its own short-lived token.
      def build_authorizer(subject)
        require "googleauth"

        @authorizers ||= {}
        @authorizers[subject] ||= begin
          creds = ::Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(credential.to_json), scope: SCOPES
          )
          creds.sub = subject
          creds
        end
      end

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

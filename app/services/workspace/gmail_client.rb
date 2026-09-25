module Workspace
  # Thin wrapper over the Gmail v1 calls the communications layer needs.
  #
  # IT CANNOT SEND, AND THAT IS THE POINT OF THIS FILE.
  #
  # Gmail's API offers exactly two ways to put mail in flight, and both are
  # named here so they can be BANNED by name rather than by intention:
  # `send_user_message` and `send_user_draft`. The second is the one that gets
  # missed — it sends an existing draft, so a codebase that carefully avoids
  # "send a message" can still post one by sending the draft it just created.
  # FORBIDDEN_GEM_CALLS is what test/lib/no_gmail_send_test.rb scans the source
  # for, so the ban and the list that enforces it cannot drift apart.
  #
  # The known gap, stated rather than papered over: the `gmail.compose` scope
  # this credential holds DOES permit sending — there is no draft-only Gmail
  # scope — so "never sends" is a property of this code, not of the grant. That
  # is precisely why it is asserted by a source scan instead of assumed.
  class GmailClient
    include ApiRetry

    FORBIDDEN_GEM_CALLS = %w[send_user_message send_user_draft].freeze

    # Metadata plus the decoded body, without the whole payload tree.
    METADATA_HEADERS = %w[From To Cc Subject Date Message-ID In-Reply-To References].freeze

    def initialize(subject: nil, credentials: Credentials, sleeper: method(:sleep), service: nil)
      @subject = subject
      @credentials = credentials
      @sleeper = sleeper
      @service = service
    end

    def service
      @service ||= begin
        require "google/apis/gmail_v1"

        ::Google::Apis::GmailV1::GmailService.new.tap do |svc|
          # :mail admits an allow-listed mailbox (alex@) as well as the workspace
          # subject — Gmail is the one surface a mailbox row opens.
          svc.authorization = @credentials.authorizer_for(@subject, purpose: :mail)
        end
      end
    end

    # `query` is Gmail's own q syntax and is REQUIRED: a defaulted listing reads
    # the whole mailbox, which is the one failure mode that must not be the
    # default. The filter rides in the REQUEST, so a non-matching message is
    # never downloaded at all.
    def messages_list(query:, cursor: nil, limit: 100)
      raise Error, "refusing to list messages without a query" if query.to_s.strip.empty?

      with_retries("messages.list", sleeper: @sleeper) do
        service.list_user_messages("me", q: query, page_token: cursor, max_results: limit)
      end
    end

    # format: "raw" gives the full RFC822 source, which is what a durable
    # snapshot wants; "metadata" gives headers only, for classification without
    # pulling bodies.
    def messages_get(id, format: "raw")
      with_retries("messages.get", sleeper: @sleeper) do
        if format == "metadata"
          service.get_user_message("me", id, format: "metadata", metadata_headers: METADATA_HEADERS)
        else
          service.get_user_message("me", id, format: format)
        end
      end
    end

    def threads_get(id, format: "metadata")
      with_retries("threads.get", sleeper: @sleeper) do
        service.get_user_thread("me", id, format: format)
      end
    end

    # --- the draft surface: creates and updates, never a send ----------------

    def drafts_create(raw:, thread_id: nil)
      with_retries("drafts.create", sleeper: @sleeper) do
        service.create_user_draft("me", draft_for(raw: raw, thread_id: thread_id))
      end
    end

    def drafts_update(id, raw:, thread_id: nil)
      with_retries("drafts.update", sleeper: @sleeper) do
        service.update_user_draft("me", id, draft_for(raw: raw, thread_id: thread_id))
      end
    end

    def drafts_get(id, format: "metadata")
      with_retries("drafts.get", sleeper: @sleeper) do
        service.get_user_draft("me", id, format: format)
      end
    end

    # The operator-facing link for a draft. The deliverable of every pipeline
    # that ends here is this URL and nothing else — a human opens it, reads it,
    # and decides.
    #
    # Pass `mailbox:` whenever it is known. `/u/0/` is whichever account the
    # browser signed in FIRST, so with several mailboxes open it lands in the
    # wrong one; `/u/<address>/` selects the mailbox the draft was written as.
    def self.draft_url(id, mailbox: nil)
      "https://mail.google.com/mail/u/#{mailbox.presence || 0}/#drafts?compose=#{id}"
    end

    private

    # HAND IT PLAIN MIME. Do not base64 it first.
    #
    # Gmail's wire format for `raw` is base64url, but the gem owns that
    # conversion in BOTH directions: representations.rb declares
    # `property :raw, :base64 => true`, so it encodes on the way out and decodes
    # on the way in. Pre-encoding therefore DOUBLE-encodes — measured on the wire
    # by test/integration/workspace_client_wiring_test.rb, which is the only tier
    # that can see it, because a service double happily accepts either string.
    #
    # The same fact matters to readers: #messages_get(format: "raw") hands back
    # DECODED MIME, not base64.
    def draft_for(raw:, thread_id:)
      require "google/apis/gmail_v1"

      message = ::Google::Apis::GmailV1::Message.new(raw: raw.to_s)
      message.thread_id = thread_id if thread_id
      ::Google::Apis::GmailV1::Draft.new(message: message)
    end
  end
end

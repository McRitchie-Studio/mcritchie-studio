module GoogleConnect
  # Changes a connected mailbox through the connection's opt-in gmail_organize
  # ability (GoogleConnection::WRITE_ABILITIES, /tasks/gmail-organize-ability):
  # mark read or unread, archive, move back to the inbox, mark spam or not
  # spam, add or remove a label, move (label and archive), and add a filter.
  # #unsubscribe (/tasks/gmail-one-click-unsubscribe) reads each matching
  # sender's List-Unsubscribe headers and, on apply, sends the RFC 8058
  # one-click POST through OneClickUnsubscribe, for one-click senders only.
  #
  # WHAT IT NEVER DOES: send mail, move to Trash, or delete. gmail.modify
  # would let it send; the source never does (test/lib/no_gmail_send_test.rb
  # scans for it). No action here names TRASH, and no method calls a delete,
  # trash or send endpoint (gmail_editor_test pins both).
  #
  # DRY FIRST. Every run lists the messages the query matches and stops there
  # unless `apply: true`; then it changes them in batches of BATCH (Gmail's
  # batchModify limit). A run without a query is refused, so nothing ever
  # touches a whole mailbox by accident. Each run, dry or applied, writes one
  # GmailChange (the audit log): the mailbox, action, query, label and counts.
  #
  # Reads ride Reader's GET; the writes are POSTs here. GmailEditor.http
  # stands in for Google in tests: (method, url, token, body) -> [status, body].
  class GmailEditor < Reader
    LABEL = "Gmail".freeze
    BASE_URL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
    MESSAGES_URL = "#{BASE_URL}/messages".freeze
    LABELS_URL = "#{BASE_URL}/labels".freeze
    FILTERS_URL = "#{BASE_URL}/settings/filters".freeze
    # Gmail's own limits: 500 ids per list page, 1,000 per batchModify.
    PAGE = 500
    BATCH = 1000
    # The most messages one run changes unless the caller asks for more.
    DEFAULT_LIMIT = 50_000
    # The most messages one unsubscribe run reads: each is its own GET.
    UNSUBSCRIBE_LIMIT = 500
    UNSUBSCRIBE_HEADERS = %w[From List-Unsubscribe List-Unsubscribe-Post].freeze

    # Each action as the system labels it adds and removes. :label stands for
    # the label the run names.
    ACTIONS = {
      "read" => { add: [], remove: %w[UNREAD] },
      "unread" => { add: %w[UNREAD], remove: [] },
      "archive" => { add: [], remove: %w[INBOX] },
      "inbox" => { add: %w[INBOX], remove: [] },
      "spam" => { add: %w[SPAM], remove: %w[INBOX] },
      "not_spam" => { add: %w[INBOX], remove: %w[SPAM] },
      "label" => { add: [ :label ], remove: [] },
      "unlabel" => { add: [], remove: [ :label ] },
      "move" => { add: [ :label ], remove: %w[INBOX] }
    }.freeze

    Error = Class.new(StandardError)
    Result = Struct.new(:action, :query, :label, :matched, :changed, :applied, :capped, :created_label, keyword_init: true)
    # One unsubscribe run: messages read, and one row per sender (kind,
    # address, name, count, and once applied the outcome).
    Unsubscribe = Struct.new(:query, :matched, :senders, :applied, :capped, keyword_init: true)

    class << self
      # Stand-in for every call: (method, url, token, body) -> [status, body].
      attr_accessor :http
    end

    def initialize(connection, requested_by:, oauth: OAuthClient)
      super(connection, oauth:)
      @requested_by = requested_by.to_s.presence || raise(Error, "a change needs requested_by")
      raise Error, "#{connection.email} has not turned on Gmail organize (/integrations)." unless connection.can?(:gmail_organize)
    end

    # Runs one action over the messages `query` matches. Dry unless apply.
    def change(action:, query:, label: nil, apply: false, limit: DEFAULT_LIMIT)
      action = action.to_s
      @changed = 0
      plan = ACTIONS.fetch(action) { raise Error, "unknown action #{action.inspect}; one of #{ACTIONS.keys.join(', ')}" }
      raise Error, "a Gmail query is required (for example: from:news@example.com older_than:1y)" if query.to_s.strip.empty?
      raise Error, "#{action} needs --label" if needs_label?(plan) && label.to_s.strip.empty?
      raise Error, "limit must be a positive number" unless limit.is_a?(Integer) && limit.positive?

      ids, capped = message_ids(query, limit:, include_spam: action == "not_spam")
      label_id, created = label_id_for(label, create: apply && plan[:add].include?(:label)) if needs_label?(plan)
      if apply && needs_label?(plan) && label_id.nil?
        raise Error, "no label named #{label.inspect} in #{@connection.email}"
      end

      changed = apply ? modify(ids, add: resolve(plan[:add], label_id), remove: resolve(plan[:remove], label_id)) : 0
      log!(action:, query:, label:, matched: ids.size, changed:, applied: apply)
      Result.new(action:, query:, label:, matched: ids.size, changed:, applied: apply, capped:, created_label: created)
    rescue OAuthClient::Error => e
      # A run Google stops part way logs the batches it did change.
      log!(action:, query:, label:, matched: ids.to_a.size, changed: @changed, applied: apply, error: e.message) if ACTIONS.key?(action)
      raise
    end

    # Adds a filter for future mail matching `query`: a label, archive, mark
    # read. Dry unless apply. The filter acts on new mail only; run #change
    # for what is already there.
    def add_filter(query:, label: nil, archive: false, mark_read: false, apply: false)
      raise Error, "a Gmail query is required for a filter" if query.to_s.strip.empty?
      raise Error, "a filter needs --label, --archive or --mark-read" if label.to_s.strip.empty? && !archive && !mark_read

      add, remove = [], []
      remove << "INBOX" if archive
      remove << "UNREAD" if mark_read
      created = false
      if label.present?
        label_id, created = label_id_for(label, create: apply)
        add << label_id if label_id
      end
      id = apply ? post_json(FILTERS_URL, { criteria: { query: }, action: { addLabelIds: add, removeLabelIds: remove } })["id"] : nil
      log!(action: "filter", query:, label:, matched: 0, changed: apply ? 1 : 0, applied: apply)
      { "filter_id" => id, "query" => query, "label" => label, "archive" => archive, "mark_read" => mark_read,
        "applied" => apply, "created_label" => created }
    end

    # Lists the messages `query` matches, groups them by sender (the newest
    # message speaks for each) and says how each sender lets you unsubscribe:
    # one-click, web-page, email-only or none. Dry unless apply. On apply it
    # sends the one-click POST for one-click senders ONLY; the others come back
    # "not unsubscribed (<kind>)" so the operator can add a filter instead. It
    # never sends mail and never opens a mailto. A dry run logs one GmailChange
    # for the run; an applied run logs one per sender it acted on, with the
    # sender as the query (from:ADDR) and any failure in error.
    def unsubscribe(query:, apply: false, limit: UNSUBSCRIBE_LIMIT)
      raise Error, "a Gmail query is required (for example: category:promotions newer_than:30d)" if query.to_s.strip.empty?
      raise Error, "limit must be a positive number" unless limit.is_a?(Integer) && limit.positive?

      ids, capped = message_ids(query, limit:, include_spam: false)
      senders = senders_of(ids)
      if apply
        senders.each { _1["outcome"] = unsubscribe_sender(_1) }
      else
        log!(action: "unsubscribe", query:, label: nil, matched: ids.size, changed: 0, applied: false)
      end
      Unsubscribe.new(query:, matched: ids.size, senders:, applied: apply, capped:)
    end

    # Every label: [{ "id", "name", "type" }], system and user.
    def labels
      Array(get_json(LABELS_URL)["labels"]).map { { "id" => _1["id"], "name" => _1["name"], "type" => _1["type"] } }
    end

    # Every filter as Gmail holds it.
    def filters = Array(get_json(FILTERS_URL)["filter"])

    private

    def needs_label?(plan) = (plan[:add] + plan[:remove]).include?(:label)

    def resolve(ids, label_id) = ids.map { _1 == :label ? label_id : _1 }

    # The ids the query matches, newest first, up to `limit`; and whether the limit cut it.
    def message_ids(query, limit:, include_spam:)
      ids = []
      token = nil
      loop do
        params = { q: query, maxResults: [ PAGE, limit - ids.size ].min }
        params[:pageToken] = token if token
        params[:includeSpamTrash] = true if include_spam
        page = get_json("#{MESSAGES_URL}?#{URI.encode_www_form(params)}")
        ids.concat(Array(page["messages"]).map { _1["id"] })
        token = page["nextPageToken"]
        return [ ids.first(limit), true ] if ids.size >= limit && token
        return [ ids, false ] if token.nil?
      end
    end

    # [the label's id, whether this run created it]; nil id when none is named
    # so and `create` is false. A name matches without regard to case. A system
    # label (TRASH, INBOX, SPAM...) is refused: --label TRASH would trash mail.
    def label_id_for(name, create:)
      found = labels.find { _1["name"].casecmp?(name.to_s.strip) }
      raise Error, "#{found['name']} is a Gmail system label; --label names your own labels only" if found && found["type"] != "user"
      return [ found["id"], false ] if found
      return [ nil, false ] unless create

      [ post_json(LABELS_URL, { name: name.to_s.strip, labelListVisibility: "labelShow", messageListVisibility: "show" })["id"], true ]
    end

    def modify(ids, add:, remove:)
      ids.each_slice(BATCH) do |slice|
        post_json("#{MESSAGES_URL}/batchModify", { ids: slice, addLabelIds: add, removeLabelIds: remove })
        @changed += slice.size
      end
      @changed
    end

    # One row per sender address, in the order the newest message of each was
    # listed: { "kind", "address", "name", "count", "uri" }.
    def senders_of(ids)
      ids.each_with_object({}) do |id, senders|
        headers = message_headers(id)
        address, name = parse_from(headers["from"])
        next if address.nil?

        if (sender = senders[address])
          sender["count"] += 1
        else
          kind = OneClickUnsubscribe.kind(headers["list-unsubscribe"], headers["list-unsubscribe-post"])
          uri = kind == "one-click" ? OneClickUnsubscribe.https_uri(headers["list-unsubscribe"]) : nil
          senders[address] = { "kind" => kind, "address" => address, "name" => name, "count" => 1, "uri" => uri }
        end
      end.values
    end

    # The three headers of one message, keyed in lower case.
    def message_headers(id)
      params = [ [ "format", "metadata" ] ] + UNSUBSCRIBE_HEADERS.map { [ "metadataHeaders", _1 ] }
      json = get_json("#{MESSAGES_URL}/#{URI.encode_www_form_component(id)}?#{URI.encode_www_form(params)}")
      Array(json.dig("payload", "headers")).to_h { [ _1["name"].to_s.downcase, _1["value"].to_s ] }
    end

    # [address in lower case, display name or nil] from a From header.
    def parse_from(value)
      text = value.to_s.strip
      address = text[/<\s*([^<>\s]+@[^<>\s]+)\s*>/, 1] || text[/\A[^\s<>"]+@[^\s<>"]+\z/]
      return [ nil, nil ] if address.nil?

      name = text.sub(/<[^>]*>\s*\z/, "").strip.delete_prefix('"').delete_suffix('"').strip
      [ address.downcase, name.presence ]
    end

    # Sends one sender's one-click POST and logs it; a sender of any other
    # kind is reported, not touched.
    def unsubscribe_sender(sender)
      return "not unsubscribed (#{sender['kind']})" unless sender["kind"] == "one-click"

      outcome = OneClickUnsubscribe.post(sender["uri"])
      error = outcome.ok ? nil : outcome.error
      log!(action: "unsubscribe", query: "from:#{sender['address']}", label: nil, matched: sender["count"],
           changed: outcome.ok ? 1 : 0, applied: true, error:)
      outcome.ok ? "unsubscribed" : "failed: #{error}"
    end

    def log!(action:, query:, label:, matched:, changed:, applied:, error: nil)
      GmailChange.create!(mailbox: @connection.email, action:, query:, label: label.presence, matched_count: matched,
                          changed_count: changed, applied:, requested_by: @requested_by, error:)
    end

    def get(url, token)
      return self.class.http.call(:get, url, token, nil) if self.class.http

      super
    end

    # The JSON of a 2xx ({} for batchModify's empty 204), or OAuthClient::Error with Google's message.
    def post_json(url, body)
      status, text = post(url, token, body.to_json)
      json = JSON.parse(text.to_s.presence || "{}") rescue {}
      raise OAuthClient::Error, "#{label} answered #{status}: #{json.dig('error', 'message') || 'no detail'}" unless (200..299).cover?(status)

      json
    end

    def post(url, token, body)
      return self.class.http.call(:post, url, token, body) if self.class.http

      uri = URI(url)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request["Authorization"] = "Bearer #{token}"
      request.body = body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "#{label} could not be reached: #{e.class}"
    end
  end
end

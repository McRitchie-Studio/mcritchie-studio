module GoogleConnect
  # Changes a connected mailbox through the connection's opt-in gmail_organize
  # ability (GoogleConnection::WRITE_ABILITIES, /tasks/gmail-organize-ability):
  # mark read or unread, archive, move back to the inbox, mark spam or not
  # spam, add or remove a label, move (label and archive), and add a filter.
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
      log!(action:, query:, label:, matched: 0, changed: 0, applied: apply, error: e.message) if ACTIONS.key?(action)
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
    # so and `create` is false. A name matches without regard to case.
    def label_id_for(name, create:)
      found = labels.find { _1["name"].casecmp?(name.to_s.strip) }
      return [ found["id"], false ] if found
      return [ nil, false ] unless create

      [ post_json(LABELS_URL, { name: name.to_s.strip, labelListVisibility: "labelShow", messageListVisibility: "show" })["id"], true ]
    end

    def modify(ids, add:, remove:)
      ids.each_slice(BATCH).sum do |slice|
        post_json("#{MESSAGES_URL}/batchModify", { ids: slice, addLabelIds: add, removeLabelIds: remove })
        slice.size
      end
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

module GoogleConnect
  # Reads the newest messages' headers from a connected account's mailbox,
  # with the gmail ability's gmail.readonly grant: the list, then each
  # message's metadata (Subject, From, Date) and Google's short snippet of it.
  # It reads no body.
  class GmailReader < Reader
    LABEL = "Gmail".freeze
    MESSAGES_URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages".freeze

    Message = Struct.new(:id, :subject, :from, :received_at, :snippet, keyword_init: true)
    Inbox = Struct.new(:estimate, :messages, keyword_init: true)

    # The `limit` newest messages, newest first, and Google's estimate of the total.
    def newest(limit: 5)
      list = get_json("#{MESSAGES_URL}?#{URI.encode_www_form(maxResults: limit)}")
      messages = Array(list["messages"]).first(limit).map { |ref| message(ref["id"]) }
      Inbox.new(estimate: list["resultSizeEstimate"].to_i, messages:)
    end

    private

    def message(id)
      query = URI.encode_www_form([ [ "format", "metadata" ], [ "metadataHeaders", "Subject" ], [ "metadataHeaders", "From" ] ])
      json = get_json("#{MESSAGES_URL}/#{ERB::Util.url_encode(id)}?#{query}")
      headers = Array(json.dig("payload", "headers")).to_h { [ _1["name"].to_s.downcase, _1["value"] ] }
      Message.new(id:, subject: headers["subject"].presence || "(no subject)", from: headers["from"],
                  snippet: CGI.unescapeHTML(json["snippet"].to_s),
                  received_at: json["internalDate"].present? ? Time.at(json["internalDate"].to_i / 1000).utc : nil)
    end
  end
end

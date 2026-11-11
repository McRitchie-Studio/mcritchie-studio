# frozen_string_literal: true

# The server half of `bin/mail`. The CLI pipes one `rails runner -` script into
# `heroku run`; that script hands a request hash to MailExport.call and prints
# the JSON answer between two markers, so the local half can pull it out of the
# dyno's noise. The desk queue, one desk item, one Gmail thread (GmailClient
# cannot send — test/lib/no_gmail_send_test.rb) and the desk health check are
# READS. The organize verbs (organize, filter, labels, filters) change a
# mailbox only through a connection whose owner turned on Gmail organize at
# /integrations (GoogleConnect::GmailEditor, /tasks/gmail-organize-ability):
# dry unless the request says apply, and logged as GmailChange either way.
# unsubscribe (/tasks/gmail-one-click-unsubscribe) rides the same connection:
# it lists senders and their unsubscribe kind, and on apply sends the RFC 8058
# one-click POST for one-click senders only. It never sends mail.
module MailExport
  ORGANIZE_VERBS = %w[organize filter labels filters unsubscribe].freeze

  module_function

  def call(request, reader: DeskCapture::Reader.new, gmail: nil, health: nil)
    return organize(request) if ORGANIZE_VERBS.include?(request["verb"])

    case request["verb"]
    when "desk_list"
      { "items" => reader.list(since: Time.current - Integer(request.fetch("since_seconds"))) }
    when "desk_item"
      { "item" => reader.item(Integer(request.fetch("id")), files: request["files"] == true) }
    when "thread"
      thread(request, gmail)
    when "doctor"
      result = (health || DeskCapture::Health.new).check
      { "ok" => result.ok?, "failures" => result.failures, "notes" => result.notes }
    else
      { "error" => "unknown verb #{request['verb'].inspect}" }
    end
  rescue ArgumentError, KeyError, Workspace::ThreadFinder::Error => e
    { "error" => e.message }
  end

  # The organize verbs, against the connection of `mailbox`.
  def organize(request)
    editor = GoogleConnect::GmailEditor.new(organize_connection(request["mailbox"]), requested_by: request["by"])
    apply = request["apply"] == true
    case request["verb"]
    when "organize"
      result = editor.change(action: request["action"], query: request["query"], label: request["label"], apply:,
                             limit: Integer(request["limit"] || GoogleConnect::GmailEditor::DEFAULT_LIMIT))
      { "result" => result.to_h.transform_keys(&:to_s) }
    when "filter"
      { "filter" => editor.add_filter(query: request["query"], label: request["label"], archive: request["archive"] == true,
                                      mark_read: request["mark_read"] == true, apply:) }
    when "unsubscribe"
      result = editor.unsubscribe(query: request["query"], apply:,
                                  limit: Integer(request["limit"] || GoogleConnect::GmailEditor::UNSUBSCRIBE_LIMIT))
      { "unsubscribe" => result.to_h.transform_keys(&:to_s).merge("senders" => result.senders.map { _1.except("uri") }) }
    when "labels" then { "labels" => editor.labels }
    when "filters" then { "filters" => editor.filters }
    end
  rescue GoogleConnect::GmailEditor::Error, GoogleConnect::OAuthClient::Error, ArgumentError => e
    { "error" => e.message }
  end

  # The mailbox's readable connection with Gmail organize on, or ArgumentError naming what is missing.
  def organize_connection(mailbox)
    email = mailbox.to_s.strip.downcase
    raise ArgumentError, "the organize verbs need --mailbox" if email.empty?

    connection = GoogleConnection.find_by(email:)
    raise ArgumentError, "#{email} is not connected (connect Gmail at /integrations)." unless connection&.readable?
    raise ArgumentError, "#{email} has not turned on Gmail organize (/integrations)." unless connection.can?(:gmail_organize)

    connection
  end

  def thread(request, gmail)
    mailbox = request["mailbox"].to_s
    query = request["query"].to_s
    return { "error" => "a Gmail query is required" } if query.strip.empty?
    return { "error" => "#{mailbox} is not an active mailbox." } unless WorkspaceMailbox.impersonatable?(mailbox)

    finder = Workspace::ThreadFinder.new(gmail || Workspace::GmailClient.new(subject: mailbox))
    export = finder.export(query, attachments: request["files"] == true)
    {
      "thread_id" => export[:thread_id],
      "transcript" => export[:transcript],
      "files" => export[:attachments].each_with_index.map { |att, idx|
        { "name" => "#{idx}-#{DeskCapture::Parser.sanitize_filename(att.filename)}",
          "base64" => Base64.strict_encode64(att.data) }
      }
    }
  end
end

# frozen_string_literal: true

# The server half of `bin/mail`. The CLI pipes one `rails runner -` script into
# `heroku run`; that script hands a request hash to MailExport.call and prints
# the JSON answer between two markers, so the local half can pull it out of the
# dyno's noise. Every verb is a READ: the desk queue, one desk item, one Gmail
# thread (GmailClient cannot send — test/lib/no_gmail_send_test.rb), or the desk
# health check.
module MailExport
  module_function

  def call(request, reader: DeskCapture::Reader.new, gmail: nil, health: nil)
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

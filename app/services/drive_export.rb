# frozen_string_literal: true

# The server half of `bin/drive` (/tasks/drive-filing). The CLI pipes one
# `rails runner -` script into `heroku run` (MailCli's transport); that script
# hands a request hash to DriveExport.call and prints the JSON answer between
# markers. Every verb goes through GoogleConnect::DriveFiler on the connection
# of `mailbox`: mkdir, upload (the file's bytes ride the request as base64,
# over the run's STDIN, never a URL or an argument), file_attachment (a Gmail
# attachment on the same account) and ls. Dry unless the request says apply.
# The answer names folders, file names, md5s and Drive ids; never the bytes,
# never a token.
module DriveExport
  VERBS = %w[mkdir upload file_attachment ls].freeze

  module_function

  def call(request, oauth: GoogleConnect::OAuthClient)
    verb = request["verb"].to_s
    return { "error" => "unknown verb #{verb.inspect}" } unless VERBS.include?(verb)

    filer = GoogleConnect::DriveFiler.new(connection(request["mailbox"]), requested_by: request["by"], oauth:)
    apply = request["apply"] == true
    case verb
    when "mkdir" then { "folder" => filer.mkdir(request["folder"], apply:) }
    when "upload"
      content = Base64.strict_decode64(request["content_base64"].to_s)
      filed(filer.upload(name: request["name"], content:, folder: request["folder"], apply:, expected_md5: request["md5"]))
    when "file_attachment"
      filed(filer.file_attachment(message_id: request["message_id"], folder: request["folder"], name: request["name"],
                                  as: request["as"], apply:))
    when "ls" then { "files" => filer.list(request["folder"]) }
    end
  rescue GoogleConnect::DriveFiler::Error, GoogleConnect::OAuthClient::Error, ArgumentError => e
    { "error" => e.message }
  end

  def filed(result) = { "filed" => result.to_h.transform_keys(&:to_s) }

  # The account's readable connection, or ArgumentError naming what is missing.
  def connection(mailbox)
    email = mailbox.to_s.strip.downcase
    raise ArgumentError, "bin/drive needs --mailbox" if email.empty?

    connection = GoogleConnection.find_by(email:)
    raise ArgumentError, "#{email} is not connected (connect Google Drive at /integrations)." unless connection&.readable?

    connection
  end
end

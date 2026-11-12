# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "securerandom"
require_relative "mail_cli"

# bin/drive — file documents into a connected account's Google Drive, in ONE
# `heroku run` per call (/tasks/drive-filing). It rides bin/mail's transport
# (MailCli.runner_script and .extract): the request goes in as base64 JSON
# inside the `rails runner -` script on the run's STDIN, and the answer comes
# back as prefixed base64 chunks. The dyno half is DriveExport.
#
# A LOCAL FILE'S BYTES take the same road: read here, base64 in the request,
# over STDIN to the dyno, with this side's md5 so the hub refuses bytes that
# arrived changed. Nothing is staged on a URL or a disk in between, and the
# bytes never sit on a command line. DriveFiler::MAX_BYTES (25 MB) caps it;
# this side refuses a bigger file before the run starts.
#
# Pure Ruby, no Rails: test/lib/drive_cli_test.rb drives it with a fake runner.
# Output names folders, file names, md5s and Drive ids; never file contents.
module DriveCli
  DEFAULT_APP = MailCli::DEFAULT_APP
  TAG = "drive"
  SERVICE = "DriveExport"
  MAX_BYTES = 25 * 1024 * 1024

  Error = Class.new(StandardError)

  USAGE = <<~TXT
    usage: bin/drive mkdir PATH --mailbox ADDR [--apply]
                                         make a folder path (Insurance/Life Insurance), reusing folders the hub made
           bin/drive upload LOCAL_FILE --folder PATH --mailbox ADDR [--as NAME] [--apply]
                                         file a local file there; a file with the same md5 already there is skipped
           bin/drive file-attachment GMAIL_MESSAGE_ID --folder PATH --mailbox ADDR [--name ATTACHMENT] [--as NAME] [--apply]
                                         file one attachment of a Gmail message on the same account (needs Gmail connected)
           bin/drive ls [PATH] --mailbox ADDR
                                         what the hub made in a folder (My Drive's top when PATH is blank)
    Dry run unless --apply. The account needs Google Drive connected at /integrations.
    The hub sees and writes only folders and files it made; it never deletes, shares or changes another file.
    common: --by NAME (the log's requester) · --app NAME (default #{DEFAULT_APP}) · --local (bin/rails runner here, not heroku)
  TXT

  module_function

  def default_options
    { app: DEFAULT_APP, local: false, mailbox: nil, folder: nil, name: nil, as: nil, apply: false,
      by: ENV["AGENT_SOUL"].to_s.strip.then { _1.empty? ? "bin/drive" : _1 } }
  end

  # Returns the exit code: 0 ok, 1 the run failed, 2 usage.
  def run(verb, args, opts, runner: nil, out: $stdout, err: $stderr, token: SecureRandom.hex(8))
    request = build_request(verb, args, opts)
    runner ||= MailCli.heroku_runner(app: opts[:app], local: opts[:local])
    stdout, stderr = runner.call(MailCli.runner_script(request, token, service: SERVICE, tag: TAG))
    answer = begin
      MailCli.extract(stdout, token, tag: TAG, service: SERVICE)
    rescue MailCli::Error => e
      err.puts "drive: #{e.message}"
      err.puts((stdout.to_s + stderr.to_s).lines.last(15).join)
      return 1
    end
    if answer["error"]
      err.puts "drive: #{answer['error']}"
      return 1
    end

    out.puts present(request["verb"], answer, request["mailbox"])
    0
  rescue Error => e
    err.puts "drive: #{e.message}"
    err.puts USAGE
    2
  end

  def build_request(verb, args, opts)
    mailbox = opts[:mailbox].to_s.strip
    raise Error, "every verb needs --mailbox ADDR (no account is ever assumed)" if mailbox.empty?

    base = { "mailbox" => mailbox, "by" => opts[:by], "apply" => opts[:apply] == true }
    case verb
    when "mkdir"
      raise Error, "mkdir takes one folder PATH (quote it)" unless args.size == 1

      base.merge("verb" => "mkdir", "folder" => args.first)
    when "upload"
      raise Error, "upload takes one LOCAL_FILE" unless args.size == 1

      base.merge("verb" => "upload", "folder" => folder!(opts)).merge(local_file(args.first, opts[:as]))
    when "file-attachment"
      raise Error, "file-attachment takes one GMAIL_MESSAGE_ID" unless args.size == 1

      base.merge("verb" => "file_attachment", "message_id" => args.first, "folder" => folder!(opts),
                 "name" => opts[:name], "as" => opts[:as])
    when "ls"
      raise Error, "ls takes at most one folder PATH" if args.size > 1

      base.merge("verb" => "ls", "folder" => args.first)
    else
      raise Error, "unknown verb #{verb.inspect}"
    end
  end

  def folder!(opts)
    folder = opts[:folder].to_s.strip
    raise Error, "--folder PATH is required (for example: --folder 'Insurance/Life Insurance')" if folder.empty?

    folder
  end

  # The file's name, md5 and bytes (base64) for the request. Refuses a
  # missing, empty, unreadable or oversized file before any run starts.
  def local_file(path, as)
    raise Error, "no file at #{path}" unless File.file?(path)
    raise Error, "#{path} is not readable" unless File.readable?(path)

    size = File.size(path)
    raise Error, "#{path} is empty" if size.zero?
    raise Error, "#{path} is #{size} bytes; the most bin/drive files is #{MAX_BYTES}" if size > MAX_BYTES

    bytes = File.binread(path)
    { "name" => as.to_s.strip.empty? ? File.basename(path) : as.to_s.strip, "md5" => Digest::MD5.hexdigest(bytes),
      "content_base64" => Base64.strict_encode64(bytes) }
  end

  def present(verb, answer, mailbox)
    case verb
    when "mkdir" then render_folder(answer["folder"], mailbox)
    when "upload", "file_attachment" then render_filed(answer["filed"], mailbox)
    when "ls" then render_list(answer["files"].to_a)
    end
  end

  def render_folder(folder, mailbox)
    path = folder["folder_path"]
    unless folder["applied"]
      missing = folder["would_create"].to_a
      return "Dry run: #{path} already exists in #{mailbox}'s Drive (#{folder['folder_id']}); nothing to make" if missing.empty?

      return "Dry run: would make #{missing.join(', ')} in #{mailbox}'s Drive\n  nothing changed: add --apply to make it"
    end
    made = folder["created"].to_a
    "#{made.empty? ? 'Found' : "Made #{made.join(', ')}; now"} #{path} in #{mailbox}'s Drive (#{folder['folder_id']})"
  end

  def render_filed(filed, mailbox)
    where = "#{filed['folder_path']} in #{mailbox}'s Drive"
    file = "#{filed['name']} (#{filed['byte_size']} bytes, md5 #{filed['md5']})"
    lines = if filed["duplicate"]
              [ "Skipped #{file}: the same file is already in #{where} (#{filed['drive_file_id']})" ]
            elsif filed["applied"]
              [ "Filed #{file} in #{where} (#{filed['drive_file_id']})" ]
            else
              [ "Dry run: would file #{file} in #{where}" ]
            end
    folders = filed["created_folders"].to_a
    lines << "  #{filed['applied'] ? 'made' : 'would make'} #{folders.join(', ')}" if folders.any?
    lines << "  #{filed['url']}" if filed["url"]
    lines << "  nothing changed: add --apply to file it" unless filed["applied"] || filed["duplicate"]
    lines.join("\n")
  end

  def render_list(files)
    return "(nothing the hub made is there)" if files.empty?

    files.map { |f| [ f["mimeType"] == "application/vnd.google-apps.folder" ? "folder" : "file", f["name"], f["id"] ].join("\t") }.join("\n")
  end
end

# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "open3"
require "securerandom"

# bin/mail — read the team@ desk and Gmail threads from a terminal, in ONE
# `heroku run` per call.
#
# The remote half is MailExport (app/services/mail_export.rb). This half builds
# a `rails runner -` script (fed over STDIN, so no shell mangles a `$` and no
# argument-length limit applies), runs it, and pulls the answer out of the
# dyno's output. The answer travels as base64 JSON chunks, each on its own line
# behind a per-call prefix, so Heroku's banner, update warnings and app log lines
# (`[mail] transport=…`) can land anywhere — before, after or between chunks —
# and are simply not selected.
#
# Pure Ruby, no Rails: test/lib/mail_cli_test.rb drives it with a fake runner.
module MailCli
  DEFAULT_APP = "mcritchie-studio"
  DEFAULT_MAILBOX = "alex@mcritchie.studio"
  CHUNK = 4096

  Error = Class.new(StandardError)

  module_function

  # "7d" / "36h" / "2w" / "90m" → seconds.
  def parse_since(text)
    m = text.to_s.strip.match(/\A(\d+)\s*([mhdw])\z/i) or
      raise Error, "--since takes <n>m|h|d|w (e.g. 7d), got #{text.inspect}"
    m[1].to_i * { "m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800 }.fetch(m[2].downcase)
  end

  # The script piped into `rails runner -`. The request rides base64 so no
  # quoting in it can break the script; the line prefix is assembled at runtime
  # so the script's own text never contains it, even if a transport echoes it.
  # `service` and `tag` let another CLI (bin/books, BooksCli) ride the same
  # transport to its own dyno half.
  def runner_script(request, token, service: "MailExport", tag: "mail")
    encoded = Base64.strict_encode64(JSON.generate(request))
    <<~RUBY
      require "base64"
      require "json"
      request = JSON.parse(Base64.strict_decode64(#{encoded.inspect}))
      answer = begin
        #{service}.call(request)
      rescue StandardError => e
        { "error" => "\#{e.class}: \#{e.message}" }
      end
      prefix = "@@#{tag}:" + #{token.inspect} + "@@ "
      Base64.strict_encode64(JSON.generate(answer)).scan(/.{1,#{CHUNK}}/m).each { |c| $stdout.puts(prefix + c) }
      $stdout.puts(prefix + "END")
      $stdout.flush
    RUBY
  end

  # Pull the answer out of everything the run printed.
  def extract(output, token, tag: "mail", service: "MailExport")
    prefix = "@@#{tag}:#{token}@@ "
    chunks = output.to_s.each_line.map { |l| l.delete_suffix("\n").delete_suffix("\r") }
                   .select { |l| l.start_with?(prefix) }.map { |l| l.delete_prefix(prefix) }
    raise Error, "no answer in the run's output (did the dyno boot? is #{service} deployed?)" if chunks.empty?
    raise Error, "the answer was cut off before its END line" unless chunks.last == "END"

    JSON.parse(Base64.strict_decode64(chunks[0...-1].join))
  end

  # Write each {name, base64} into dir. A name is reduced to its basename so a
  # payload can never write outside the folder the operator chose.
  def write_files(dir, files)
    FileUtils.mkdir_p(dir)
    Array(files).map do |f|
      name = File.basename(f.fetch("name").to_s)
      name = "file" if name.empty? || name.start_with?(".")
      path = File.join(dir, name)
      File.binwrite(path, Base64.strict_decode64(f.fetch("base64")))
      path
    end
  end

  def default_dir(label)
    File.join(ENV.fetch("TMPDIR", "/tmp"), "mail", label)
  end

  # --- rendering --------------------------------------------------------------

  def render_list(items)
    return "(no desk items in that window)" if items.empty?

    items.map { |i|
      line = "##{i['id']}  #{i['received_at']}  #{i['source']}/#{i['status']}  #{i['from']}  — #{i['subject']}"
      i["attachments"].to_a.empty? ? line : "#{line}\n      attachments: #{i['attachments'].join(', ')}"
    }.join("\n")
  end

  def render_item(item)
    head = [
      "Desk item ##{item['id']} (#{item['source']}, #{item['status']})",
      "From:     #{item['from']}",
      "Subject:  #{item['subject']}",
      "Received: #{item['received_at']}",
      ("Entity:   #{item['entity_hint']}" if item["entity_hint"]),
      ("Attach:   #{item['attachments'].join(', ')}" if item["attachments"].to_a.any?)
    ].compact
    if item["quarantined"]
      (head + [ "", item["notice"], item["dkim"] ]).join("\n")
    else
      (head + [ "", item["body"].to_s ]).join("\n")
    end
  end

  def render_doctor(answer)
    lines = answer["failures"].to_a.map { |f| "FAIL #{f}" } + answer["notes"].to_a.map { |n| "ok   #{n}" }
    lines << (answer["ok"] ? "desk health OK" : "desk health FAILED")
    lines.join("\n")
  end

  # --- the command ------------------------------------------------------------

  USAGE = <<~TXT
    usage: bin/mail desk [--since 7d]                 list desk items (team@ and the Gmail read)
           bin/mail desk <id> [--save [DIR]]          print one item; --save writes its .eml and attachments
           bin/mail thread '<gmail query>' [--mailbox ADDR] [--save [DIR]]
                                                      print one thread; --save writes transcript and attachments
           bin/mail doctor                            the desk health check (MX + dropped ingests)
           bin/mail organize ACTION '<gmail query>' --mailbox ADDR [--label NAME] [--limit N] [--apply]
                                                      ACTION: #{%w[read unread archive inbox spam not_spam label unlabel move].join(' ')}
                                                      dry run (a count) unless --apply; move = label + archive
           bin/mail filter '<gmail query>' --mailbox ADDR [--label NAME] [--archive] [--mark-read] [--apply]
                                                      a filter for future mail; dry unless --apply
           bin/mail unsubscribe '<gmail query>' --mailbox ADDR [--limit N] [--apply]
                                                      each sender and how it unsubscribes (one-click, web-page,
                                                      email-only, none); --apply unsubscribes one-click senders only
           bin/mail labels --mailbox ADDR             every label · bin/mail filters --mailbox ADDR  every filter
    organize needs the mailbox's Gmail organize turned on at /integrations. It never sends or deletes.
    common: --app NAME (default #{DEFAULT_APP}) · --local (run bin/rails runner here, not heroku) · --by NAME (the log's requester)
  TXT

  # The real transport: one heroku run (or a local rails runner), script on STDIN.
  def heroku_runner(app:, local:)
    lambda do |script|
      cmd = local ? %w[bin/rails runner -] : [ "heroku", "run", "-a", app, "--no-tty", "--", "rails", "runner", "-" ]
      out, err, _status = Open3.capture3(*cmd, stdin_data: script)
      [ out, err ]
    end
  end

  def default_options
    { app: DEFAULT_APP, local: false, mailbox: DEFAULT_MAILBOX, mailbox_given: false, since: "7d", save: nil,
      label: nil, limit: nil, apply: false, archive: false, mark_read: false, by: ENV["AGENT_SOUL"].to_s.strip.then { _1.empty? ? "bin/mail" : _1 } }
  end

  # Returns the exit code. bin/mail has already parsed the flags into `opts`
  # and left the positionals in `args`. `runner` takes the script and returns
  # [stdout, stderr]; the default is one heroku run.
  def run(verb, args, opts, runner: nil, out: $stdout, err: $stderr, token: SecureRandom.hex(8))
    request = build_request(verb, args, opts)
    runner ||= heroku_runner(app: opts[:app], local: opts[:local])
    stdout, stderr = runner.call(runner_script(request, token))
    answer = begin
      extract(stdout, token)
    rescue Error => e
      err.puts "mail: #{e.message}"
      err.puts((stdout.to_s + stderr.to_s).lines.last(15).join)
      return 1
    end
    if answer["error"]
      err.puts "mail: #{answer['error']}"
      return 1
    end

    present(verb, request, answer, opts, out)
  rescue Error => e
    err.puts "mail: #{e.message}"
    err.puts USAGE
    2
  end

  def build_request(verb, args, opts)
    case verb
    when "desk"
      raise Error, "desk takes at most one id" if args.size > 1
      return { "verb" => "desk_list", "since_seconds" => parse_since(opts[:since]) } if args.empty?
      raise Error, "desk id must be a number, got #{args.first.inspect}" unless args.first.match?(/\A\d+\z/)

      { "verb" => "desk_item", "id" => args.first.to_i, "files" => !opts[:save].nil? }
    when "thread"
      raise Error, "thread takes exactly one Gmail query (quote it)" unless args.size == 1

      { "verb" => "thread", "query" => args.first, "mailbox" => opts[:mailbox], "files" => !opts[:save].nil? }
    when "doctor"
      raise Error, "doctor takes no arguments" unless args.empty?

      { "verb" => "doctor" }
    when "organize"
      raise Error, "organize takes ACTION and one Gmail query (quote it)" unless args.size == 2

      organize_request(opts).merge("verb" => "organize", "action" => args[0], "query" => args[1], "label" => opts[:label],
                                   "limit" => opts[:limit], "apply" => opts[:apply])
    when "filter"
      raise Error, "filter takes one Gmail query (quote it)" unless args.size == 1

      organize_request(opts).merge("verb" => "filter", "query" => args[0], "label" => opts[:label], "archive" => opts[:archive],
                                   "mark_read" => opts[:mark_read], "apply" => opts[:apply])
    when "unsubscribe"
      raise Error, "unsubscribe takes one Gmail query (quote it)" unless args.size == 1

      organize_request(opts).merge("verb" => "unsubscribe", "query" => args[0], "limit" => opts[:limit], "apply" => opts[:apply])
    when "labels", "filters"
      raise Error, "#{verb} takes no arguments" unless args.empty?

      organize_request(opts).merge("verb" => verb)
    else
      raise Error, "unknown verb #{verb.inspect}"
    end
  end

  def present(verb, request, answer, opts, out)
    case request["verb"]
    when "desk_list"
      out.puts render_list(answer["items"].to_a)
      0
    when "desk_item"
      item = answer["item"]
      out.puts render_item(item)
      save(opts, "desk-#{item['id']}", item["files"], out) unless item["quarantined"]
      out.puts "\n(--save wrote nothing: quarantined items are reported, never processed)" if item["quarantined"] && opts[:save]
      0
    when "thread"
      out.puts answer["transcript"]
      if opts[:save]
        transcript = { "name" => "transcript.txt", "base64" => Base64.strict_encode64(answer["transcript"].to_s) }
        save(opts, "thread-#{answer['thread_id']}", [ transcript ] + answer["files"].to_a, out)
      end
      0
    when "doctor"
      out.puts render_doctor(answer)
      answer["ok"] ? 0 : 1
    when "organize"
      out.puts render_change(answer["result"], request["mailbox"])
      0
    when "filter"
      out.puts render_filter(answer["filter"], request["mailbox"])
      0
    when "unsubscribe"
      out.puts render_unsubscribe(answer["unsubscribe"], request["mailbox"])
      0
    when "labels"
      out.puts answer["labels"].to_a.sort_by { [ _1["type"].to_s, _1["name"].to_s.downcase ] }.map { "#{_1['type']}\t#{_1['name']}" }
      0
    when "filters"
      out.puts JSON.pretty_generate(answer["filters"].to_a)
      0
    else
      raise Error, "unhandled verb #{verb}"
    end
  end

  # The organize verbs act on a mailbox named on the command line, never the default.
  def organize_request(opts)
    raise Error, "the organize verbs need --mailbox ADDR (the default mailbox is never assumed)" unless opts[:mailbox_given]

    { "mailbox" => opts[:mailbox], "by" => opts[:by] }
  end

  def render_change(result, mailbox)
    verb = result["applied"] ? "Changed #{result['changed']} of #{result['matched']}" : "Dry run: #{result['matched']} match"
    lines = [ "#{verb} message(s) in #{mailbox}: #{result['action']}#{" #{result['label'].inspect}" if result['label']} for #{result['query'].inspect}" ]
    lines << "  (stopped at the limit; run again for the rest, or raise --limit)" if result["capped"]
    lines << "  created label #{result['label'].inspect}" if result["created_label"]
    lines << "  nothing changed: add --apply to make this change" unless result["applied"]
    lines.join("\n")
  end

  # One row per sender: kind, address, name, message count, and once applied what happened.
  def render_unsubscribe(result, mailbox)
    senders = result["senders"].to_a
    head = result["applied"] ? "Unsubscribe in #{mailbox}" : "Dry run: unsubscribe in #{mailbox}"
    lines = [ "#{head} for #{result['query'].inspect}: #{result['matched']} message(s), #{senders.size} sender(s)" ]
    lines << "  (stopped at the limit; raise --limit to read more)" if result["capped"]
    senders.each do |s|
      row = [ s["kind"].ljust(10), s["address"], s["name"].to_s.empty? ? "-" : s["name"], "#{s['count']} msg" ]
      row << s["outcome"] if s["outcome"]
      lines << "  #{row.join("\t")}"
    end
    if result["applied"]
      done = senders.count { _1["outcome"] == "unsubscribed" }
      lines << "  #{done} unsubscribed; for the rest, add a filter (bin/mail filter 'from:ADDR' --archive)"
    else
      lines << "  nothing changed: add --apply to unsubscribe the #{senders.count { _1['kind'] == 'one-click' }} one-click sender(s)"
    end
    lines.join("\n")
  end

  def render_filter(filter, mailbox)
    does = [ ("label #{filter['label'].inspect}" if filter["label"]), ("archive" if filter["archive"]), ("mark read" if filter["mark_read"]) ].compact.join(", ")
    head = filter["applied"] ? "Filter #{filter['filter_id']} added in #{mailbox}" : "Dry run: would add a filter in #{mailbox}"
    "#{head}: #{filter['query'].inspect} -> #{does}#{"\n  nothing changed: add --apply to add it" unless filter['applied']}"
  end

  def save(opts, label, files, out)
    return if opts[:save].nil?

    dir = opts[:save] == :default ? default_dir(label) : File.expand_path(opts[:save])
    paths = write_files(dir, files)
    out.puts "\nSaved #{paths.size} file(s) to #{dir}:"
    paths.each { |p| out.puts "  #{p}" }
  end
end

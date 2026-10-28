# frozen_string_literal: true

require "base64"
require "json"
require "securerandom"
require_relative "mail_cli"

# bin/books: the month-close bookkeeping from a terminal, one `heroku run` per
# call. The remote half is Books::Export (app/services/books/export.rb); the
# transport is bin/mail's (MailCli.runner_script / .extract), so the request
# rides STDIN and no shell mangles a `$`.
#
# Pure Ruby, no Rails: test/lib/books_cli_test.rb drives it with a fake runner.
module BooksCli
  TAG = "books"
  SERVICE = "Books::Export"

  Error = Class.new(StandardError)

  USAGE = <<~TXT
    usage: bin/books setup <entity>                       create the Drive folders; print their links
           bin/books status <entity>                      statements, unread Inbox files, lines waiting, closes
           bin/books intake <entity> [--file PDF ...]     file the Inbox, or these PDFs
           bin/books unclassified <entity>                the lines waiting for an answer
           bin/books classify <entity> <id> [<id> ...] --category KEY [--purpose TEXT] [--note TEXT]
                                                          record what lines were (--category none clears)
           bin/books close <entity> <YYYY-MM>             write the month's Sheet and PDF to Drive
    common: --by WHO (required for intake, classify, close: who decided or ran it)
            --app NAME (default #{MailCli::DEFAULT_APP}) · --local (bin/rails runner here, not heroku)
    SOP: docs/agents/agents/mack/sops/close-the-month.md
  TXT

  module_function

  def default_options = { app: MailCli::DEFAULT_APP, local: false, files: [], by: nil }

  def build_request(verb, args, opts)
    entity = args.shift or raise Error, "name the entity (e.g. studio)"
    base = { "verb" => verb, "entity" => entity }
    case verb
    when "setup", "status", "unclassified"
      raise Error, "#{verb} takes only the entity" unless args.empty?

      base
    when "intake"
      raise Error, "intake takes only the entity and --file" unless args.empty?

      files = opts[:files].map do |path|
        raise Error, "no such file #{path}" unless File.file?(path)

        { "name" => File.basename(path), "base64" => Base64.strict_encode64(File.binread(path)) }
      end
      base.merge("by" => by!(opts), "files" => (files unless files.empty?)).compact
    when "classify"
      raise Error, "classify takes line ids" if args.empty?
      raise Error, "line ids are numbers, got #{args.join(' ')}" unless args.all? { |a| a.match?(/\A\d+\z/) }
      raise Error, "classify needs --category (or --category none)" if opts[:category].nil?

      base.merge("ids" => args.map(&:to_i), "category" => (opts[:category] == "none" ? nil : opts[:category]),
                 "purpose" => opts[:purpose], "note" => opts[:note], "by" => by!(opts))
    when "close"
      month = args.shift or raise Error, "close takes a month, YYYY-MM"
      raise Error, "month must be YYYY-MM, got #{month}" unless month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
      raise Error, "close takes only the entity and one month" unless args.empty?

      base.merge("month" => month, "by" => by!(opts))
    else
      raise Error, "unknown verb #{verb.inspect}"
    end
  end

  def by!(opts) = opts[:by].to_s.strip.empty? ? raise(Error, "say who is running this: --by NAME") : opts[:by]

  # --- rendering --------------------------------------------------------------

  def render(verb, answer)
    case verb
    when "setup"
      lines = answer["folders"].map { |k, v| "#{k.ljust(10)} #{v}" }
      lines << "in #{answer['owner']}'s Drive#{", shared with #{answer['shared_with']}" if answer['shared_with']}" if answer["owner"]
      lines.join("\n")
    when "status" then render_status(answer)
    when "intake" then render_intake(answer)
    when "unclassified" then render_lines(answer["lines"], empty: "(no lines waiting)")
    when "classify" then render_lines(answer["classified"], empty: "(nothing classified)")
    when "close" then render_close(answer)
    end
  end

  def render_status(a)
    out = [ a["entity"] ]
    a["accounts"].each { |x| out << "  #{x['account'].ljust(24)} #{x['statements']} statement(s), through #{x['through'] || '-'}" }
    out << "  Inbox, not yet read: #{a['inbox_unread'].empty? ? 'none' : a['inbox_unread'].join(', ')}"
    out << "  Lines waiting for an answer: #{a['unclassified']}"
    a["closes"].each { |c| out << "  close #{c['month']} #{c['status'].upcase} #{c['sheet']}" }
    out.join("\n")
  end

  def render_intake(a)
    out = a["results"].map do |r|
      s = r["statement"]
      line = "#{r['status'].upcase.ljust(14)} #{r['name']}"
      line += "  → #{s['account']} #{s['period']}, #{s['entries']} line(s), #{s['unclassified']} waiting" if s
      (r["problems"].to_a + r["warnings"].to_a).each { |p| line += "\n    #{p}" }
      line
    end
    out = [ "(nothing new in the Inbox)" ] if out.empty?
    out << ""
    out << "Lines waiting for an answer:"
    out << render_lines(a["unclassified"], empty: "  none")
    out.join("\n")
  end

  def render_lines(lines, empty:)
    return empty if lines.to_a.empty?

    lines.map do |l|
      tail = l["category"] ? "  = #{l['category']}#{" (#{l['purpose']})" if l['purpose']}" : ""
      "  ##{l['id'].to_s.ljust(6)} #{l['date']}  #{l['account'].ljust(13)} #{l['amount'].rjust(16)}  #{l['description']}#{tail}"
    end.join("\n")
  end

  def render_close(a)
    s = a["summary"]
    out = [ "#{a['month']} close: #{a['status'].upcase}",
            "  Sheet: #{a['sheet']}", "  PDF:   #{a['pdf']}",
            "  Net income, year to date #{money(s['net_income_ytd_cents'])} · cash #{money(s['cash_cents'])} · " \
            "equity #{money(s['equity_cents'])} · #{s['unclassified']} line(s) waiting" ]
    a["checks"].each { |c| out << "  #{c['ok'] ? 'ok  ' : 'OPEN'} #{c['label']}: #{c['detail']}" }
    a["notes"].to_a.each { |n| out << "  note: #{n}" }
    out.join("\n")
  end

  # 123456 → "$1,234.56", negatives in parentheses (Books.money, without Rails).
  def money(cents)
    whole, frac = format("%.2f", cents.abs / 100.0).split(".")
    text = "$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{frac}"
    cents.negative? ? "(#{text})" : text
  end

  # Returns the exit code. `runner` takes the script and returns [stdout, stderr].
  def run(verb, args, opts, runner: nil, out: $stdout, err: $stderr, token: SecureRandom.hex(8))
    request = build_request(verb, args.dup, opts)
    runner ||= MailCli.heroku_runner(app: opts[:app], local: opts[:local])
    stdout, stderr = runner.call(MailCli.runner_script(request, token, service: SERVICE, tag: TAG))
    answer = begin
      MailCli.extract(stdout, token, tag: TAG, service: SERVICE)
    rescue MailCli::Error => e
      err.puts "books: #{e.message}"
      err.puts((stdout.to_s + stderr.to_s).lines.last(15).join)
      return 1
    end
    if answer["error"]
      err.puts "books: #{answer['error']}"
      return 1
    end

    out.puts render(verb, answer)
    verb == "intake" && answer["results"].any? { |r| r["status"] == "refused" } ? 1 : 0
  rescue Error => e
    err.puts "books: #{e.message}"
    err.puts USAGE
    2
  end
end

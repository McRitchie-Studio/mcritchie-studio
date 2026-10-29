# frozen_string_literal: true

# [unit] bin/lib/books_cli.rb — the local half of bin/books. No Heroku, no Rails:
# the runner executes the generated script in a plain `ruby` subprocess with a
# stub Books::Export, salted with the noise a real `heroku run` prints.
#
#   ruby -Itest test/lib/books_cli_test.rb

require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/books_cli"

class BooksCliTest < Minitest::Test
  TOKEN = "t0k3n"

  def runner(answer: nil)
    lambda do |script|
      stub = <<~RUBY
        module Books
          module Export
            def self.call(request)
              #{answer ? "JSON.parse(#{JSON.generate(answer).inspect})" : '{ "echo" => request }'}
            end
          end
        end
        puts "[books] boot"
      RUBY
      out, err, status = Open3.capture3("ruby", stdin_data: stub + script)
      raise "script failed: #{err}" unless status.success?

      [ "Running rails runner - on ⬢ mcritchie-studio... up\n#{out}heroku-cli: update available\n", err ]
    end
  end

  def run_cli(verb, args, opts = {}, answer:)
    out = StringIO.new
    err = StringIO.new
    code = BooksCli.run(verb, args, BooksCli.default_options.merge(opts), runner: runner(answer: answer), out: out, err: err, token: TOKEN)
    [ code, out.string, err.string ]
  end

  def test_the_request_round_trips_through_a_real_ruby_process_with_dollar_signs_intact
    request = BooksCli.build_request("classify", %w[studio 12 13], BooksCli.default_options.merge(
      category: "member_distribution", purpose: "Acquisition costs", note: "Alex: $3,000 broker", by: "alex"
    ))
    out, = runner.call(MailCli.runner_script(request, TOKEN, service: BooksCli::SERVICE, tag: BooksCli::TAG))

    echo = MailCli.extract(out, TOKEN, tag: BooksCli::TAG)["echo"]
    assert_equal [ 12, 13 ], echo["ids"]
    assert_equal "Alex: $3,000 broker", echo["note"]
  end

  def test_intake_sends_the_files_it_is_given
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sep.pdf")
      File.binwrite(path, "%PDF-1.4 bytes")
      request = BooksCli.build_request("intake", %w[studio], BooksCli.default_options.merge(files: [ path ], by: "alex"))

      assert_equal [ { "name" => "sep.pdf", "base64" => "JVBERi0xLjQgYnl0ZXM=" } ], request["files"]
    end
  end

  def test_writes_need_a_who_and_a_well_formed_argument
    assert_raises(BooksCli::Error) { BooksCli.build_request("close", %w[studio 2026-09], BooksCli.default_options) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("close", %w[studio 2026-13], BooksCli.default_options.merge(by: "a")) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("classify", %w[studio x1], BooksCli.default_options.merge(by: "a", category: "bank_fees")) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("classify", %w[studio 1], BooksCli.default_options.merge(by: "a")) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("close", %w[studio 2026-09 extra], BooksCli.default_options.merge(by: "a")) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("status", %w[studio extra], BooksCli.default_options) }
    assert_nil BooksCli.build_request("classify", %w[studio 1], BooksCli.default_options.merge(by: "a", category: "none"))["category"]
  end

  def test_close_prints_the_status_links_figures_and_open_checks
    answer = { "month" => "2026-09", "status" => "draft", "sheet" => "https://drive/s", "pdf" => "https://drive/p",
               "summary" => { "net_income_ytd_cents" => 644_354, "cash_cents" => 2_414_354, "equity_cents" => 2_414_354, "unclassified" => 5 },
               "checks" => [ { "label" => "Every line is classified", "ok" => false, "detail" => "5 line(s) need an answer" } ], "notes" => [] }
    code, out, = run_cli("close", %w[studio 2026-09], { by: "alex" }, answer: answer)

    assert_equal 0, code
    assert_includes out, "2026-09 close: DRAFT"
    assert_includes out, "Net income, year to date $6,443.54 · cash $24,143.54"
    assert_includes out, "OPEN Every line is classified: 5 line(s) need an answer"
  end

  def test_lender_takes_a_month_and_a_who_and_prints_its_links_and_figures
    assert_raises(BooksCli::Error) { BooksCli.build_request("lender", %w[industries 2026-09], BooksCli.default_options) }
    assert_raises(BooksCli::Error) { BooksCli.build_request("lender", %w[industries], BooksCli.default_options.merge(by: "a")) }
    request = BooksCli.build_request("lender", %w[industries 2026-09], BooksCli.default_options.merge(by: "mack"))
    assert_equal({ "verb" => "lender", "entity" => "industries", "month" => "2026-09", "by" => "mack" }, request)

    answer = { "month" => "2026-09", "status" => "draft", "sheet" => "https://drive/ls", "pdf" => "https://drive/lp",
               "summary" => { "net_income_ytd_cents" => -70_000, "cash_cents" => 100_000, "equity_cents" => 2_200_000,
                              "capitalized_cents" => 2_100_000, "unclassified" => 3 },
               "checks" => [], "notes" => [ "the ledger changed since the 2026-09 close ran" ] }
    code, out, = run_cli("lender", %w[industries 2026-09], { by: "mack" }, answer: answer)

    assert_equal 0, code
    assert_includes out, "2026-09 lender package: DRAFT"
    assert_includes out, "Sheet: https://drive/ls"
    assert_includes out, "Capitalized (deal costs and other assets) $21,000.00"
    assert_includes out, "note: the ledger changed"
  end

  def test_status_prints_each_close_cash_and_the_oldest_waiting_line
    answer = { "entity" => "X LLC", "accounts" => [], "inbox_unread" => [], "unclassified" => 3, "oldest_waiting" => "2026-09-24",
               "closes" => [ { "month" => "2026-09", "status" => "draft", "sheet" => "https://drive/s", "cash_cents" => 2_414_354,
                               "lender_sheet" => "https://drive/ls" } ] }
    code, out, = run_cli("status", %w[industries], {}, answer: answer)

    assert_equal 0, code
    assert_includes out, "Lines waiting for an answer: 3 (oldest 2026-09-24)"
    assert_includes out, "close 2026-09 DRAFT cash $24,143.54 https://drive/s"
    assert_includes out, "lender package https://drive/ls"
  end

  def test_a_refused_statement_exits_one
    answer = { "results" => [ { "name" => "x.pdf", "status" => "refused", "problems" => [ "credit lines total $1.00" ] } ], "unclassified" => [] }
    code, out, = run_cli("intake", %w[studio], { by: "alex" }, answer: answer)

    assert_equal 1, code
    assert_includes out, "REFUSED"
    assert_includes out, "credit lines total $1.00"
  end

  def test_a_server_error_is_reported_and_exits_one
    code, _out, err = run_cli("status", %w[studio], {}, answer: { "error" => "no entity \"stdio\"" })

    assert_equal 1, code
    assert_includes err, "books: no entity"
  end

  def test_money
    assert_equal "$1,234.56", BooksCli.money(123_456)
    assert_equal "($40,000.00)", BooksCli.money(-4_000_000)
  end
end

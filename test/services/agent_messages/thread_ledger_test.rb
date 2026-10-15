require "test_helper"
require_relative "../../support/agent_message_fixtures"

module AgentMessages
  # [unit] The context bundle's selection (AgentMessages::ThreadLedger): one
  # person's ledger per channel per soul, the reply pin, the verbatim window and
  # the extractive summary fold, the notes about the sender.
  class ThreadLedgerTest < ActiveSupport::TestCase
    include AgentMessageFixtures

    ALEX = "500".freeze
    BEA = "501".freeze

    setup { @t0 = Time.zone.parse("2026-10-14 12:00:00") }

    def exchange!(content, at:, author: ALEX, soul: "xan", channel_ref: DESK, answer: nil, status: nil, **attrs)
      agent_message!(soul: soul, content: content, author_ref: author, channel_ref: channel_ref, sent_at: at,
                     created_at: at, status: status || (answer ? "completed" : "received"), response_text: answer,
                     author_name: author == ALEX ? "Alex" : "Bea", **attrs)
    end

    def bundle(message) = ThreadLedger.new(message).bundle

    test "the ledger holds only this person's earlier exchanges with this soul in this channel, oldest first" do
      first = exchange!("what is building?", at: @t0 - 2.hours, answer: "Two tasks.")
      second = exchange!("and in review?", at: @t0 - 1.hour, answer: "One PR.")
      exchange!("bea asks xan", at: @t0 - 90.minutes, author: BEA, answer: "Hi Bea.")
      exchange!("alex asks avi", at: @t0 - 80.minutes, soul: "avi", answer: "Release green.")
      exchange!("alex elsewhere", at: @t0 - 70.minutes, channel_ref: QUIET, answer: "Elsewhere.")
      current = exchange!("thanks, and next?", at: @t0)
      exchange!("a later one", at: @t0 + 1.minute)

      ledger = bundle(current)["ledger"]

      assert_equal [ first.id, second.id ], ledger["turns"].map { |t| t["id"] }
      assert_equal "Two tasks.", ledger["turns"].first["answer"]
      assert_equal 2, ledger["total"]
      assert_nil ledger["pin"], "a message that started its own thread pins nothing"
      assert_empty ledger.dig("summary", "lines")
    end

    test "a message with no author id has no ledger rather than everyone's" do
      exchange!("anon earlier", at: @t0 - 1.hour, author: "", answer: "x")
      current = exchange!("anon now", at: @t0, author: "")

      assert_empty bundle(current).dig("ledger", "turns")
    end

    test "turns past the last ten, or older than seven days, fold into an extractive summary" do
      old = exchange!("a week-old question\nwith a second line", at: @t0 - 8.days, answer: "an old answer\nmore")
      recent = (1..11).map { |i| exchange!("question #{i}", at: @t0 - (12 - i).hours, answer: "answer #{i}") }
      current = exchange!("now", at: @t0)

      ledger = bundle(current)["ledger"]

      assert_equal recent.last(10).map(&:id), ledger["turns"].map { |t| t["id"] }, "the last ten, verbatim"
      summary = ledger["summary"]
      assert_equal 2, summary["turns"]
      assert_equal [ "#{(@t0 - 8.days).to_date.iso8601} asked: a week-old question | answered: an old answer",
                     "#{(@t0 - 11.hours).to_date.iso8601} asked: question 1 | answered: answer 1" ], summary["lines"]
      assert_equal 0, summary["omitted"]
      assert_includes ledger["turns"].map { |t| t["id"] }, recent[1].id
      refute_includes ledger["turns"].map { |t| t["id"] }, old.id
    end

    test "the window is measured from the message's own sent time, so a rebuild later is identical" do
      exchange!("six days before", at: @t0 - 6.days, answer: "fresh")
      current = exchange!("now", at: @t0)

      first = bundle(current)
      travel_to(@t0 + 30.days) { assert_equal first, bundle(current) }
      assert_equal 1, first.dig("ledger", "turns").size
    end

    test "the summary keeps the newest SUMMARY_LINES and cuts each side to SUMMARY_SIDE" do
      stub_const(ThreadLedger, :SUMMARY_LINES, 2) do
        exchange!("x" * 400, at: @t0 - 30.days, answer: "y")
        exchange!("second", at: @t0 - 29.days, answer: "y")
        exchange!("third", at: @t0 - 28.days)
        current = exchange!("now", at: @t0)

        summary = bundle(current).dig("ledger", "summary")
        assert_equal 3, summary["turns"]
        assert_equal 1, summary["omitted"]
        assert_match(/asked: second \| answered: y\z/, summary["lines"].first)
        assert_match(/asked: third \| answered: \(no answer\)\z/, summary["lines"].last)
      end
      long = ThreadLedger.new(AgentMessage.new).send(:first_line, "z" * 400)
      assert_equal ThreadLedger::SUMMARY_SIDE, long.length
      assert long.end_with?("…")
    end

    test "an explicit reply pins the latest earlier row of its thread, even another person's, and drops it from the turns" do
      mine = exchange!("my question", at: @t0 - 3.hours, answer: "my answer")
      root = exchange!("bea's question", at: @t0 - 2.hours, author: BEA, answer: "bea's answer")
      reply = exchange!("replying to bea's thread", at: @t0, thread_key: root.thread_key)

      ledger = bundle(reply)["ledger"]

      assert_equal root.id, ledger.dig("pin", "id")
      assert_equal "bea's answer", ledger.dig("pin", "answer")
      assert_equal [ mine.id ], ledger["turns"].map { |t| t["id"] }, "Bea's other rows stay out; mine stay in"
    end

    test "a pinned exchange from the sender's own ledger is not repeated as a turn" do
      older = exchange!("older", at: @t0 - 3.hours, answer: "a1")
      root = exchange!("root", at: @t0 - 2.hours, answer: "a2")
      reply = exchange!("follow-up", at: @t0, thread_key: root.thread_key)

      ledger = bundle(reply)["ledger"]
      assert_equal root.id, ledger.dig("pin", "id")
      assert_equal [ older.id ], ledger["turns"].map { |t| t["id"] }
    end

    test "the notes about the sender are read by (channel, author_ref)" do
      AgentUserNote.create!(channel: "discord", author_ref: ALEX, display_name: "Alex M", notes: "Owner. Prefers short answers.")
      AgentUserNote.create!(channel: "discord", author_ref: BEA, notes: "Not Alex.")
      current = exchange!("hi", at: @t0)

      assert_equal({ "display_name" => "Alex M", "notes" => "Owner. Prefers short answers." },
                   bundle(current)["user"].slice("display_name", "notes"))
      assert_nil bundle(exchange!("hi", at: @t0, author: "502"))["user"]
    end

    private

    def stub_const(klass, name, value)
      old = klass.const_get(name)
      klass.send(:remove_const, name)
      klass.const_set(name, value)
      yield
    ensure
      klass.send(:remove_const, name)
      klass.const_set(name, old)
    end
  end
end

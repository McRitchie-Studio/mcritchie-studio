# frozen_string_literal: true

# [unit] AgentMailbox::Dispatcher.raise_detail: what a raised answer run's error
# message may carry into the dispatcher log and the board's release reason. The
# error names the cause; it must never carry the message's or the answer's text,
# which parser and encoding errors quote back.
#   ruby -Itest test/lib/agent_dispatcher_raise_detail_test.rb
require "minitest/autorun"
require "json"
require_relative "../../bin/lib/agent_dispatcher"

class AgentDispatcherRaiseDetailTest < Minitest::Test
  def detail(error) = AgentMailbox::Dispatcher.raise_detail(error)

  def raised
    yield
    flunk "expected a raise"
  rescue StandardError => e
    e
  end

  def test_the_incident_error_reads_in_full
    error = raised { "café".b.force_encoding(Encoding::US_ASCII).gsub(/x/, "y") }
    assert_equal "invalid byte sequence in US-ASCII", detail(error)
  end

  def test_a_parser_error_quoting_the_message_text_is_redacted
    error = raised { JSON.parse("{\"reply\": tell nobody the secret plan}") }
    refute_includes detail(error), "secret plan"
    assert_match(/…/, detail(error))
  end

  # Ruby names one offending character (U+00E9, or a quoted "\xC3"), never the
  # text around it; a quoted one is redacted all the same.
  def test_an_encoding_error_names_at_most_the_character_never_the_text
    error = raised { "café private words".encode(Encoding::US_ASCII) }
    assert_equal "U+00E9 from UTF-8 to US-ASCII", detail(error)
    error = raised { "café private words".b.encode(Encoding::UTF_8) }
    assert_equal "… from ASCII-8BIT to UTF-8", detail(error)
  end

  def test_only_the_first_line_is_kept_and_it_is_capped
    error = ArgumentError.new("#{'a' * 300}\nsecond line with message text")
    assert_equal AgentMailbox::Dispatcher::RAISE_DETAIL_LIMIT, detail(error).length
    assert detail(error).end_with?("…")
    refute_includes detail(error), "second line"
  end

  def test_single_and_backtick_quotes_and_invalid_bytes
    error = ArgumentError.new("bad 'quoted text' and `ticked text` \xFF end".b)
    assert_equal "bad … and … � end", detail(error)
    assert detail(error).valid_encoding?
  end
end

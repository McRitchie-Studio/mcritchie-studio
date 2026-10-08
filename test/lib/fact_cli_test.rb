# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/fact_cli"

# [unit] bin/fact with the hub API faked: what each run asks the hub for, what it
# prints, and which session token it presents.
class FactCliTest < Minitest::Test
  VALUE = "prefers-the-east-gate-41c9"

  class FakeApi
    attr_reader :calls

    def initialize(answer) = (@answer = answer; @calls = [])
    def get(path) = (@calls << [:get, path]; @answer)
    def post(path, payload = nil) = (@calls << [:post, path, payload]; @answer)
  end

  def fact(**extra)
    { "slug" => "fact-0123456789abcdef", "subject_type" => "person", "subject_slug" => "josh-allen", "key" => "gate",
      "value" => VALUE, "pointer" => false, "sensitivity" => "ordinary",
      "source" => { "kind" => "knowledge_doc", "ref" => "doc-1", "note" => nil }, "recorded_by" => "pokemon",
      "recorded_at" => "2026-10-07T12:00:00Z" }.merge(extra.transform_keys(&:to_s))
  end

  def run_cli(argv, answer)
    api = FakeApi.new(answer)
    out = StringIO.new
    FactCli::Runner.new(api: api, out: out).run(FactCli.parse(argv))
    [api.calls, out.string]
  end

  def test_a_bare_slug_lists_a_persons_current_facts_with_their_source
    calls, out = run_cli(%w[josh-allen], [fact])

    assert_equal [[:get, "/api/v1/facts?subject_type=person&subject_slug=josh-allen"]], calls
    assert_includes out, "gate: #{VALUE}"
    assert_includes out, "source doc-1 · recorded by pokemon 2026-10-07"
  end

  def test_a_sensitive_value_is_masked_until_reveal
    sensitive = fact(sensitivity: "sensitive")

    refute_includes run_cli(%w[company/acme], [sensitive]).last, VALUE
    assert_includes run_cli(%w[company/acme --reveal], [sensitive]).last, VALUE
  end

  def test_add_posts_the_fact_and_the_confirmation_never_repeats_the_value
    calls, out = run_cli(["person/josh-allen", "--add", "gate=#{VALUE}", "--source", "drive:1AbC", "--note", "page 2"], fact)

    assert_equal [[:post, "/api/v1/facts", { fact: { subject_type: "person", subject_slug: "josh-allen", key: "gate", value: VALUE,
                                                     source_note: "page 2", source_kind: "drive_file", source_ref: "1AbC" } }]], calls
    assert_includes out, "recorded fact-0123456789abcdef"
    refute_includes out, VALUE
  end

  def test_a_bare_key_posts_a_pointer_with_no_value
    calls, out = run_cli(%w[josh-allen --add ssn --source drive:1AbC], fact(key: "ssn", value: nil, pointer: true))

    refute calls.first.last[:fact].key?(:value)
    assert_includes out, "ssn, pointer"
  end

  def test_supersede_and_retire_name_the_fact_by_slug
    calls, = run_cli(%w[--supersede fact-aa --value west --source doc-9], fact)
    assert_equal [:post, "/api/v1/facts/fact-aa/supersede", { fact: { value: "west", source_kind: "knowledge_doc", source_ref: "doc-9" } }],
                 calls.first

    calls, out = run_cli(%w[--retire fact-aa], fact)
    assert_equal [:post, "/api/v1/facts/fact-aa/retire", nil], calls.first
    assert_includes out, "retired fact-0123456789abcdef"
  end

  def test_parse_refuses_what_it_cannot_run
    { %w[josh-allen --add gate=x] => /--add needs --source/,
      %w[team/bills] => /unknown subject type/,
      %w[] => /exactly one subject/,
      %w[a b] => /exactly one subject/,
      %w[--supersede fact-aa --value x] => /needs --value and --source/,
      %w[josh-allen --retire fact-aa] => /take a fact slug, not a subject/ }.each do |argv, message|
      error = assert_raises(FactCli::Failure, argv.inspect) { FactCli.parse(argv) }
      assert_match message, error.message
    end
    assert_raises(OptionParser::InvalidOption) { FactCli.parse(%w[josh-allen --frobnicate]) }
  end

  def test_help_asks_the_hub_for_nothing
    assert FactCli.parse(%w[--help])[:help]
  end

  def with_desk(session)
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, ".git"))
      DeskSession.write(root, session) if session
      yield root
    end
  end

  def test_the_token_is_the_admin_one_else_the_desks_own_live_session
    now = Time.utc(2026, 10, 7, 12)
    live = { "token" => "desk-token", "harness_session_id" => "harness-1", "expires_at" => (now + 3600).iso8601 }
    mine = { "CLAUDE_CODE_SESSION_ID" => "harness-1" }

    with_desk(live) do |root|
      assert_equal "desk-token", FactCli.session_token(env: mine, root: root, now: now)
      assert_equal "admin-token", FactCli.session_token(env: mine.merge("AGENT_ADMIN_SESSION_TOKEN" => "admin-token\n"), root: root, now: now)
      assert_nil FactCli.session_token(env: { "CLAUDE_CODE_SESSION_ID" => "harness-2" }, root: root, now: now), "another harness"
      assert_nil FactCli.session_token(env: {}, root: root, now: now), "no harness named"
      assert_nil FactCli.session_token(env: mine, root: root, now: now + 7200), "expired"
    end
    with_desk(nil) { |root| assert_nil FactCli.session_token(env: mine, root: root, now: now) }
  end

  def test_a_refusal_carries_the_hubs_reason
    refusal = Net::HTTPUnprocessableEntity.new("1.1", "422", "Unprocessable")
    refusal.instance_variable_set(:@read, true)
    refusal.instance_variable_set(:@body, JSON.generate("error" => "store a pointer to the original", "error_code" => "IDENTITY_REFUSED"))
    api = FactCli::Api.new(base_url: "http://localhost:1", token: "t")

    error = assert_raises(FactCli::Failure) { api.send(:data, refusal) }
    assert_equal "hub answered 422: IDENTITY_REFUSED store a pointer to the original", error.message
  end
end

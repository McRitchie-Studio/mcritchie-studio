require "test_helper"

# [unit] AgentProposals::TurfOperator (the hub's client for Turf Monster's
# operator endpoint) and AgentProposals::Operations (the named operations a
# `go` runs): bounded calls, fail-closed wiring, refusals as operator copy,
# results formatted in code. docs/agents/system/agent-message-loop.md, "Operations".
class AgentProposalsOperationsTest < ActiveSupport::TestCase
  TOKEN = "op-token-should-never-print".freeze

  # Records each request; answers queued [code, body Hash or String].
  class Transport
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def call(verb, uri, body, headers)
      @calls << { verb: verb, uri: uri, body: body && JSON.parse(body), headers: headers }
      code, payload = @answers.shift || [ 500, "" ]
      [ code, payload.is_a?(String) ? payload : JSON.generate(payload) ]
    end
  end

  def client(*answers, env: { AgentProposals::TurfOperator::TOKEN_ENV => TOKEN })
    @transport = Transport.new(*answers)
    AgentProposals::TurfOperator.new(env: env, base_url: "https://turf.example", transport: @transport)
  end

  def proposal(params = {})
    person = AgentPerson.create!(display_name: "Alex McRitchie")
    go = AgentMessage.create!(channel: "slack", external_id: "C1:#{SecureRandom.hex(4)}", thread_key: "slack:C1:1.0",
                              channel_ref: "C1", guild_id: "T1", author_ref: "U1", author_name: "Alex", person: person,
                              content: "go", soul_slug: "turf_monster", routed_by: "thread", status: "completed")
    AgentProposal.create!(thread_key: "slack:C1:1.0", channel: "slack", guild_id: "T1", channel_ref: "C1",
                          soul_slug: "turf_monster", kind: "operate", capability: "cancel_contest", params: params,
                          summary: "Cancel", status: "confirmed", confirm_message: go, expires_at: 1.day.from_now)
  end

  test "not wired: with no token nothing is sent" do
    c = client(env: {})
    error = assert_raises(AgentProposals::TurfOperator::NotWired) { c.contests }
    assert_match(/OPERATOR_TOKEN_TURF_MONSTER is unset/, error.message)
    assert_empty @transport.calls
  end

  test "the bearer is sent, and no error message ever carries it" do
    c = client([ 401, { "error" => "unauthorized" } ])
    error = assert_raises(AgentProposals::TurfOperator::Error) { c.contests(scope: "all", limit: 5) }
    assert_equal "HTTP 401 token mismatch", error.message
    call = @transport.calls.sole
    assert_equal "Bearer #{TOKEN}", call[:headers]["Authorization"]
    assert_equal "/_operator/contests", call[:uri].path
    assert_equal({ "scope" => "all", "limit" => "5" }, URI.decode_www_form(call[:uri].query).to_h)
    refute_includes error.message, TOKEN
  end

  test "a slug that is not a slug is refused before anything is sent" do
    c = client
    assert_raises(AgentProposals::TurfOperator::Refused) do
      c.cancel(slug: "../admin", paid_entries: "none", requested_by: "x", request_ref: "y")
    end
    assert_empty @transport.calls
  end

  test "cancel_contest posts the frozen params, names who said go, and formats the queued result" do
    p = proposal("contest" => "nfl-weeks-8-10", "paid_entries" => "none")
    c = client([ 200, { "schema" => 1, "state" => "queued", "slug" => "nfl-weeks-8-10", "name" => "NFL Weeks 8-10",
                        "pending_transaction_id" => 41, "entries" => 0, "paid_entries" => 0,
                        "treasury_path" => "/admin/pending_transactions" } ])

    text, result = AgentProposals::Operations.run("cancel_contest", p.params, proposal: p, client: c)

    call = @transport.calls.sole
    assert_equal [ :post, "/_operator/contests/nfl-weeks-8-10/cancel" ], [ call[:verb], call[:uri].path ]
    assert_equal "none", call[:body]["paid_entries"]
    assert_equal "agent_proposal:#{p.id}", call[:body]["request_ref"]
    assert_match(/Alex McRitchie \(person \d+\), go on slack for agent proposal #{p.id}/, call[:body]["requested_by"])
    assert_equal "Cancel of NFL Weeks 8-10 (`nfl-weeks-8-10`) queued for your cosign: " \
                 "https://turf.example/admin/pending_transactions Nothing is on chain until your wallet signs it there. " \
                 "0 entries, 0 paid.", text
    assert_equal({ "operation" => "cancel_contest", "contest" => "nfl-weeks-8-10", "state" => "queued",
                   "pending_transaction_id" => 41, "paid_entries" => 0, "url" => "https://turf.example/admin/pending_transactions" },
                 result)
  end

  test "an already-waiting cancel says nothing new was queued; paid entries name the choice and the human step" do
    p = proposal("contest" => "wk", "paid_entries" => "refund")
    c = client([ 200, { "state" => "already_queued", "slug" => "wk", "name" => "Wk", "entries" => 3, "paid_entries" => 2,
                        "paid_entries_choice" => "refund", "treasury_path" => "/admin/pending_transactions" } ])
    text, = AgentProposals::Operations.run("cancel_contest", p.params, proposal: p, client: c)
    assert_match(/already waiting for your cosign, so nothing new was queued/, text)
    assert_match(/3 entries, 2 paid\. You chose refund for the paid entries/, text)
    assert_match(%r{cancelled-contest-refunds\.md}, text)
  end

  test "Turf's refusal becomes an Operations::Refused with its copy" do
    p = proposal("contest" => "wk")
    c = client([ 422, { "error" => "paid_entries_need_choice", "message" => "Wk has 2 paid entries. Say whether they are refunded or credited before it is cancelled." } ])
    error = assert_raises(AgentProposals::Operations::Refused) do
      AgentProposals::Operations.run("cancel_contest", p.params, proposal: p, client: c)
    end
    assert_equal "Turf refused it: Wk has 2 paid entries. Say whether they are refunded or credited before it is cancelled.", error.message
  end

  test "create_contest returns the pre-filled link and the format, and creates nothing" do
    c = client([ 200, { "state" => "ready", "path" => "/contests/new?contest%5Bweek_span%5D=3&contest_type=medium&slate_id=7",
                        "year" => 2026, "weeks" => "Weeks 10-12", "format" => "medium", "entry_fee_cents" => 1900,
                        "max_entries" => 9, "prize_cents" => 14_000 } ])
    text, result = AgentProposals::Operations.run("create_contest", { "week" => 10, "weeks" => 3, "season" => "regular",
                                                                      "contest_type" => "medium" }, proposal: nil, client: c)
    assert_equal({ "week" => 10, "weeks" => 3, "season" => "regular", "contest_type" => "medium" }, @transport.calls.sole[:body])
    assert_equal "Ready to create a medium contest on NFL 2026 Weeks 10-12 ($19 entry, 9 max, $140 in prizes): " \
                 "https://turf.example/contests/new?contest%5Bweek_span%5D=3&contest_type=medium&slate_id=7 " \
                 "Open it, check the form, and sign the create in Phantom; nothing is created until you do.", text
    assert_equal "create_contest", result["operation"]
  end

  test "an operation the module does not name is refused" do
    assert_raises(AgentProposals::Operations::Unknown) { AgentProposals::Operations.run("drop_table", {}, proposal: nil, client: client) }
  end

  test "the contests read lists what a cancel would touch" do
    c = client([ 200, { "contests" => [
      { "slug" => "nfl-8-10", "name" => "NFL Weeks 8-10", "weeks" => "Weeks 8-10", "format" => "medium", "status" => "open",
        "locked" => true, "entries" => 4, "max_entries" => 9, "paid_entries" => 3 },
      { "slug" => "old", "name" => "Old", "format" => "tiny", "status" => "open", "cancelled" => true, "entries" => 0,
        "max_entries" => 3, "paid_entries" => 0 }
    ] } ])
    text = AgentProposals::Queries.run("turf_contests", { "scope" => "open", "limit" => 10 }, operator: c)
    assert_equal "Turf Monster contests (open, newest first):\n" \
                 "- `nfl-8-10` NFL Weeks 8-10 · Weeks 8-10 · medium · open, locked · 4/9 entries, 3 paid\n" \
                 "- `old` Old · tiny · cancelled · 0/3 entries, 0 paid", text
  end

  test "the contests read is Unavailable, with the reason, when the endpoint is not wired" do
    error = assert_raises(AgentProposals::Queries::Unavailable) do
      AgentProposals::Queries.run("turf_contests", {}, operator: client(env: {}))
    end
    assert_match(/not wired/, error.message)
  end
end

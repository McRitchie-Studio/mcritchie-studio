require "test_helper"

# [component] /communications — the real controller, the real ERB. Proves the
# page renders, that the filters narrow what they claim to, and that the gate
# holds for a non-admin.
#
# Synthetic entities and addresses throughout: this repo is PUBLIC, and a
# fixture that names a real counterparty ends up in failure output.
class CommunicationsIndexTest < ActionDispatch::IntegrationTest
  ENTITY = "synthetic-entity".freeze
  OTHER  = "other-entity".freeze

  setup do
    @admin = users(:alex)

    @old_general = Communication.create!(
      kind: "general", channel: "fathom", entity: ENTITY, external_id: "f-1",
      occurred_at: 9.days.ago, subject: "Kickoff call transcript"
    )
    @new_general = Communication.create!(
      kind: "general", channel: "sms", entity: OTHER, external_id: "s-1",
      occurred_at: 2.hours.ago, subject: "Quick confirmation"
    )
    @open_ask = Communication.create!(
      kind: "ask", channel: "email", entity: ENTITY, external_id: "e-1",
      occurred_at: 1.hour.ago, status: "open",
      ask_text: "Draft a reply about the revised schedule.",
      key_points: [ "The date moved", "The figure did not" ]
    )
    @delivered_ask = Communication.create!(
      kind: "ask", channel: "email", entity: ENTITY, external_id: "e-2",
      occurred_at: 3.days.ago, status: "delivered",
      ask_text: "Ask for the appraisal summary.",
      deliverable_url: "https://mail.google.com/mail/u/0/#drafts?compose=d1"
    )
  end

  test "an anonymous visitor cannot reach it" do
    get communications_path

    refute_equal 200, response.status,
      "the page renders deal correspondence — it must not be open"
  end

  test "a SIGNED-IN non-admin cannot reach it either" do
    # The stronger half of the gate. "Not 200 while anonymous" is satisfied by
    # any sign-in redirect and says nothing about roles; this is the assertion
    # that would catch require_admin being dropped for a plain authenticate.
    log_in_as users(:viewer)
    get communications_path

    refute_equal 200, response.status
    refute_includes response.body.to_s, "Draft a reply about the revised schedule."
  end

  test "an admin sees every row, asks above general" do
    log_in_as @admin
    get communications_path

    assert_response :success
    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @open_ask.id, @delivered_ask.id, @new_general.id, @old_general.id ], ids,
      "asks first, then newest first"
  end

  test "it renders the ask text, the key points, and the deliverable link" do
    log_in_as @admin
    get communications_path

    assert_includes response.body, "Draft a reply about the revised schedule."
    assert_includes response.body, "The date moved"
    assert_includes response.body, "compose=d1"
  end

  test "the kind filter narrows to asks" do
    log_in_as @admin
    get communications_path(kind: "ask")

    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @open_ask.id, @delivered_ask.id ], ids
    refute_includes ids, @new_general.id
  end

  test "the status filter narrows to one lifecycle state" do
    log_in_as @admin
    get communications_path(status: "delivered")

    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @delivered_ask.id ], ids
  end

  test "the channel filter narrows to one mouth" do
    log_in_as @admin
    get communications_path(channel: "fathom")

    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @old_general.id ], ids
  end

  test "the entity filter narrows, and only entities with rows are offered" do
    log_in_as @admin
    get communications_path(entity: ENTITY)

    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @open_ask.id, @delivered_ask.id, @old_general.id ], ids
    assert_includes response.body, ENTITY
  end

  test "filters compose rather than replacing each other" do
    log_in_as @admin
    get communications_path(kind: "ask", entity: ENTITY, status: "open")

    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten.map(&:to_i)
    assert_equal [ @open_ask.id ], ids
  end

  test "a bogus filter value is ignored, not passed to the query" do
    # A hand-edited URL must not become an unfiltered dump or a 500.
    log_in_as @admin
    get communications_path(kind: "memo", status: "pondering", channel: "carrier_pigeon")

    assert_response :success
    ids = response.body.scan(/data-comm-id="(\d+)"/).flatten
    assert_equal 4, ids.size, "unknown values drop out and the page shows everything"
  end

  test "a STRUCTURED entity param is ignored, not a 500" do
    # entity[x]=1 arrives as nested Parameters, which the filter links cannot
    # turn back into a query string — the page raised instead of rendering.
    log_in_as @admin
    get communications_path(entity: { x: "1" })

    assert_response :success
    assert_equal 4, response.body.scan(/data-comm-id="(\d+)"/).size
  end

  test "a privileged row is LABELLED but its body is not rendered" do
    secret_body = "synthetic-privileged-body-marker"
    Communication.create!(kind: "general", channel: "call", entity: ENTITY, external_id: "p-1",
                          occurred_at: 1.day.ago, subject: "Counsel call",
                          body_text: secret_body, privileged: true)

    log_in_as @admin
    get communications_path

    assert_includes response.body, "privileged", "the operator must see that it exists"
    refute_includes response.body, secret_body,
      "a list page renders no bodies — least of all this one"
  end

  test "an empty filter says so instead of rendering a bare table" do
    log_in_as @admin
    get communications_path(channel: "pocket")

    assert_response :success
    assert_includes response.body, "Nothing recorded yet"
  end

  test "the counts summarise the record" do
    log_in_as @admin
    get communications_path

    assert_match(/1 open ask\b/, response.body)
    assert_match(/2 asks/, response.body)
    assert_match(/2 general/, response.body)
  end
end

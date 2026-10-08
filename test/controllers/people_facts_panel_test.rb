require "test_helper"

# [integration] The person page's facts panel: each fact with its source and the
# facts it replaced, for an admin only.
class PeopleFactsPanelTest < ActionDispatch::IntegrationTest
  CURRENT = "prefers-the-west-gate-2c6d".freeze
  REPLACED = "prefers-the-east-gate-9a1b".freeze

  setup do
    @session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
    @person = people(:josh_allen)
  end

  def record(**attrs)
    Fact.create!({ subject_type: "person", subject_slug: @person.slug, source_kind: "knowledge_doc", source_ref: "doc-1",
                   recorded_by_session_slug: @session.slug }.merge(attrs))
  end

  def fact_queries
    seen = []
    callback = ->(*, payload) { seen << payload[:sql] if payload[:sql].match?(/FROM "facts"/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    seen
  end

  test "[integration] an admin sees each fact with its source and its history" do
    old = record(key: "gate", value: REPLACED, source_note: "intake call")
    old.supersede!(value: CURRENT, source_kind: "drive_file", source_ref: "drive-77", recorded_by_session_slug: @session.slug)
    record(key: "ssn", value: nil, source_kind: "drive_file", source_ref: "drive-ssn")
    record(key: "band", value: "seven", sensitivity: "sensitive").retire!
    record(subject_type: "company", subject_slug: @person.slug, key: "other", value: "a company's fact")
    log_in_as users(:alex)

    get person_path(@person.slug)

    assert_response :success
    assert_select "[data-test=facts-panel] [data-test=fact-row]", 3
    assert_select "[data-test=fact-row]", text: /gate/ do
      assert_select "[data-test=fact-value]", text: CURRENT
      assert_select "a[href='https://drive.google.com/file/d/drive-77/view']"
      assert_select "[data-test=fact-history] [data-test=fact-history-row]", 1 do
        assert_select "[data-test=fact-value]", text: REPLACED
        assert_select "[data-test=fact-source]", text: /knowledge doc\s+doc-1\s+\(intake call\)\s+· recorded by steffon/
      end
    end
    assert_select "[data-test=fact-pointer]", 1
    assert_select "[data-test=fact-retired]", 1
    assert_not_includes response.body, "a company's fact"
  end

  test "[integration] an admin with no facts sees the empty state (control)" do
    log_in_as users(:alex)

    queries = fact_queries { get person_path(@person.slug) }

    assert_select "[data-test=facts-empty]", 1
    assert_equal 1, queries.size, "the panel reads the person's facts in one query"
  end

  test "[integration] a visitor is sent to sign-in and no fact is read" do
    record(key: "gate", value: CURRENT)

    queries = fact_queries { get person_path(@person.slug) }

    assert_redirected_to "/login"
    assert_empty queries
  end

  test "[integration] without an encryption key the panel says so and the page renders" do
    record(key: "gate", value: CURRENT)
    log_in_as users(:alex)

    Fact.stub(:encryption_ready?, false) { get person_path(@person.slug) }

    assert_response :success
    assert_select "[data-test=facts-unavailable]", 1
    assert_not_includes response.body, CURRENT
  end
end

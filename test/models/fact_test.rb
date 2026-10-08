require "test_helper"

# [unit] Fact: an encrypted record about a subject, with its source and history.
class FactTest < ActiveSupport::TestCase
  SECRET_VALUE = "prefers-a-window-seat-7f3a".freeze

  setup do
    @session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
    @person = people(:josh_allen)
  end

  def build(**attrs)
    Fact.new({ subject_type: "person", subject_slug: @person.slug, key: "seat", value: SECRET_VALUE,
               source_kind: "knowledge_doc", source_ref: "doc-123", recorded_by_session_slug: @session.slug }.merge(attrs))
  end

  test "[unit] an ordinary value saves with a slug, a sensitivity and a recorded time (control)" do
    fact = build
    assert fact.save, fact.errors.full_messages.to_sentence
    assert_match(/\Afact-[0-9a-f]{16}\z/, fact.slug)
    assert_equal "ordinary", fact.sensitivity
    assert fact.recorded_at.present?
    assert_equal SECRET_VALUE, Fact.find(fact.id).value
  end

  test "[unit] test_value_is_ciphertext_at_rest" do
    fact = build.tap(&:save!)
    stored = Fact.connection.select_value("SELECT value FROM facts WHERE id = #{fact.id.to_i}")
    assert stored.present?
    assert_not_includes stored, SECRET_VALUE
    assert_not_includes fact.inspect, SECRET_VALUE
  end

  test "[unit] validates subject, key, sensitivity and source" do
    assert_includes build(subject_type: "team").tap(&:valid?).errors.attribute_names, :subject_type
    assert_includes build(subject_slug: "nobody-on-file").tap(&:valid?).errors.attribute_names, :subject_slug
    assert_includes build(subject_type: "company", subject_slug: "Not A Slug").tap(&:valid?).errors.attribute_names, :subject_slug
    assert build(subject_type: "company", subject_slug: "acme-welding").valid?, "company slugs are free"
    assert_includes build(key: " ").tap(&:valid?).errors.attribute_names, :key
    assert_includes build(sensitivity: "secret").tap(&:valid?).errors.attribute_names, :sensitivity
    assert_includes build(source_kind: "rumour").tap(&:valid?).errors.attribute_names, :source_kind
    assert_includes build(source_ref: nil).tap(&:valid?).errors.attribute_names, :source_ref
  end

  IDENTITY_VALUES = {
    "ssn" => "123-45-6789",
    "card" => "4111 1111 1111 1111",
    "routing" => "routing 021000021",
    "account" => "acct # 000123456789",
    "password" => "password: hunter2!"
  }.freeze

  test "[unit] test_refuses_ssn_account_routing_card_password" do
    IDENTITY_VALUES.each do |kind, value|
      fact = build(key: "note", value: value)
      assert_not fact.save, "#{kind} value saved"
      message = fact.errors[:value].to_sentence
      assert_match(/store a pointer to the original/, message, kind)
      assert_no_match(/#{Regexp.escape(value)}/, message, "the refusal repeats the value")
    end
    assert_equal 0, Fact.count
  end

  test "[unit] an identity-class key takes a pointer, never a value" do
    refused = build(key: "SSN", value: "on file")
    assert_not refused.valid?
    assert_match(/store a pointer to the original/, refused.errors[:value].to_sentence)

    pointer = build(key: "ssn", value: nil, source_kind: "drive_file", source_ref: "1AbCdEf")
    assert pointer.save, pointer.errors.full_messages.to_sentence
    assert pointer.pointer?
  end

  test "[unit] an identity value in the source note is refused (the note is not encrypted)" do
    fact = build(source_note: "his SSN is 123-45-6789")
    assert_not fact.valid?
    assert_match(/store a pointer to the original/, fact.errors[:source_note].to_sentence)
  end

  test "[unit] a value needs something to say: a blank value is a pointer only for an identity key" do
    assert_includes build(value: nil).tap(&:valid?).errors.attribute_names, :value
  end

  test "[unit] ordinary look-alikes save: a phone number, an EIN, a dollar figure (control)" do
    ["(303) 222-2113", "84-1234567", "$1,250,000.00 in 2025", "born 1996-05-21"].each do |value|
      assert build(value: value).valid?, "#{value} was refused"
    end
  end

  test "[unit] supersede! links the predecessor to its successor and keeps its source" do
    old = build.tap(&:save!)
    successor = old.supersede!(value: "prefers an aisle seat", source_kind: "drive_file", source_ref: "drive-9",
                               recorded_by_session_slug: @session.slug)

    assert_equal successor.slug, old.reload.superseded_by_slug
    assert_equal %w[knowledge_doc doc-123], [old.source_kind, old.source_ref]
    assert_equal [old.subject_type, old.subject_slug, old.key], [successor.subject_type, successor.subject_slug, successor.key]
    assert_equal [successor], Fact.current.for_subject("person", @person.slug).to_a
    assert_equal [[successor, [old]]], Fact.chains(Fact.for_subject("person", @person.slug).newest_first.to_a)
  end

  test "[unit] a superseded or retired fact cannot be superseded again" do
    old = build.tap(&:save!)
    old.supersede!(value: "v2", source_ref: "doc-2", recorded_by_session_slug: @session.slug)
    assert_raises(ActiveRecord::RecordInvalid) { old.supersede!(value: "v3", source_ref: "doc-3", recorded_by_session_slug: @session.slug) }

    retired = build(key: "team").tap(&:save!)
    retired.retire!
    assert retired.retired?
    assert_empty Fact.current.where(key: "team")
    assert_raises(ActiveRecord::RecordInvalid) { retired.supersede!(value: "x", source_ref: "d", recorded_by_session_slug: @session.slug) }
  end

  test "[unit] a person rename carries the person's facts and leaves a company's of the same slug" do
    person = Person.create!(first_name: "Factual", last_name: "Renamer")
    mine = build(subject_slug: person.slug).tap(&:save!)
    theirs = build(subject_type: "company", subject_slug: person.slug).tap(&:save!)

    person.rename_slug!("factual-renamed")

    assert_equal "factual-renamed", mine.reload.subject_slug
    assert_equal "factual-renamer", theirs.reload.subject_slug
  end

  test "[unit] a merge hands the source person's facts to the keeper" do
    keep = Person.create!(first_name: "Factual", last_name: "Keeper")
    source = Person.create!(first_name: "Factual", last_name: "Source")
    fact = build(subject_slug: source.slug).tap(&:save!)

    People::Merge.call!(keep: keep, source: source)

    assert_equal keep.slug, fact.reload.subject_slug
  end
end

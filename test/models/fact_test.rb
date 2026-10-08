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
    { "phone" => "(303) 222-2113", "ein" => "84-1234567", "dollars" => "$1,250,000.00 in 2025",
      "date" => "born 1996-05-21" }.each do |label, value|
      assert build(value: value).valid?, "the #{label} look-alike was refused"
    end
  end

  def refused(attribute, **attrs)
    fact = build(**attrs)
    assert_not fact.save, "saved: #{attrs.keys.join(", ")}"
    fact.errors[attribute].to_sentence
  end

  def assert_pointer_refusal(attribute, label, digits: nil, **attrs)
    message = refused(attribute, **attrs)
    assert_match(/store a pointer to the original/, message, label)
    assert_no_match(/#{Regexp.escape(digits)}/, message, "#{label}: the refusal repeats the data") if digits
  end

  BANK_DIGITS = "000123456789".freeze
  SSN_DIGITS = "123-45-6789".freeze

  test "[unit] a key is a name: lowercase words and digits joined by a hyphen or an underscore" do
    { "a space" => "home town", "upper case" => "HomeTown", "a dot" => "home.town", "an equals sign" => "home=town",
      "a trailing hyphen" => "home-", "a doubled hyphen" => "home--town", "too long" => "a" * 65 }.each do |label, key|
      assert_match(/lowercase words and digits/, refused(:key, key: key), label)
    end
    assert_equal 0, Fact.count

    %w[year-founded year_founded naics 401k-match q3-2025-revenue].push("a" * 64).each do |key|
      assert build(key: key).save, "an ordinary key was refused (control): #{key}"
    end
  end

  test "[unit] a colon typed for the equals sign is refused: 'ssn: digits' stores nothing" do
    assert_pointer_refusal(:key, "ssn: digits", digits: SSN_DIGITS, key: "ssn: #{SSN_DIGITS}", value: nil)
    assert_equal 0, Fact.count

    assert build(key: "ssn", value: nil).save, "the pointer the message names saves (control)"
  end

  test "[unit] a key that carries identity data is refused whatever joins it" do
    { "ssn, hyphens" => "ssn-#{SSN_DIGITS}", "ssn, underscores" => "ssn_123_45_6789", "ssn, no name" => SSN_DIGITS,
      "an account run" => "acct-#{BANK_DIGITS}", "a card" => "card-4111-1111-1111-1111", "a pin" => "pin-4321",
      "a long number" => "note-#{BANK_DIGITS}", "digits in pieces" => "n-12-34-56-78",
      "a password" => "password: hunter2!" }.each do |label, key|
      assert_pointer_refusal(:key, label, key: key, value: nil)
      assert_pointer_refusal(:key, "#{label}, with a value", key: key, value: "on file")
    end
    assert_equal 0, Fact.count

    assert build(key: "401k-account", value: nil).save, "an identity-named key with a short number points (control)"
    assert build(key: "form-1099-count", value: "three").save, "an ordinary key with a short number saves (control)"
  end

  IDENTITY_KEYS = %w[bank_account checking-account account acct acct-no card credit-card debit_card card-number routing
                     routing-number aba iban cvv ssn social-security itin passport passport-number drivers-license
                     driver_licence license-number password passwd pwd passcode passphrase pin pin-code].freeze

  test "[unit] bank_account=digits is refused: every identity-named key takes a pointer, never a value" do
    assert_pointer_refusal(:value, "bank_account=digits", digits: BANK_DIGITS, key: "bank_account", value: BANK_DIGITS)
    IDENTITY_KEYS.each do |key|
      assert_pointer_refusal(:value, "#{key} with a word", key: key, value: "on file")
      assert_pointer_refusal(:value, "#{key} with digits", digits: BANK_DIGITS, key: key, value: BANK_DIGITS)
    end
    assert_equal 0, Fact.count

    IDENTITY_KEYS.each { |key| assert build(key: key, value: nil).save, "#{key} did not save as a pointer (control)" }
  end

  test "[unit] words beside an identity word stay ordinary keys (control)" do
    %w[account-manager account_executive accounting-firm accounts-payable-contact operating-bank business-card
       scorecard pinned-post licensing-model spinoff].each do |key|
      assert build(key: key, value: "an ordinary answer").save, "#{key} was refused"
    end
  end

  test "[unit] a person's tax id or licence is identity; a company's EIN and an app's licence are ordinary" do
    %w[ein fein tin tax-id taxpayer_id license licence].each do |key|
      assert_pointer_refusal(:value, "person #{key}", key: key, value: "84-1234567")
      assert build(key: key, value: nil).save, "person #{key} did not save as a pointer (control)"
    end

    company = { subject_type: "company", subject_slug: "acme-welding" }
    assert build(**company, key: "ein", value: "84-1234567").save
    assert build(**company, key: "tax-id", value: "841234567").save
    assert build(subject_type: "app", subject_slug: "turf-monster", key: "license", value: "MIT").save
  end

  test "[unit] an unformatted long number is refused as a value unless the key is a numeric one" do
    assert_pointer_refusal(:value, "a bank number under an ordinary key", digits: BANK_DIGITS, key: "note", value: BANK_DIGITS)
    assert_pointer_refusal(:value, "a number sent as a number", key: "note", value: BANK_DIGITS.to_i + 9_000_000_000_000)
    assert_pointer_refusal(:value, "nine bare digits", key: "note", value: "123456789")
    assert_pointer_refusal(:value, "eight bare digits in a sentence", key: "note", value: "the number is 12345678 at the bank")
    assert_pointer_refusal(:value, "the ssn with dots", key: "note", value: "123.45.6789")
    assert_pointer_refusal(:value, "an underscored account", key: "note", value: "bank_account_no 123456")
    assert_pointer_refusal(:value, "a pin", key: "note", value: "PIN: 4321")
    assert_pointer_refusal(:value, "a passport", key: "note", value: "passport no. X1234567")
    assert_equal 0, Fact.count

    assert build(key: "note", value: "1234567").save, "seven digits save (control)"
  end

  test "[unit] the numeric keys admit their own shape of number and no other" do
    company = { subject_type: "company", subject_slug: "acme-welding" }
    { "ein" => "841234567", "duns" => "123456789", "sos-id" => "20201234567", "business-phone" => "3032222113",
      "zip" => "802051234", "formed" => "20200115", "naics" => "332710", "headcount" => "14",
      "revenue" => "$12,500,000" }.each do |key, value|
      assert build(**company, key: key, value: value).save, "company #{key} was refused (control)"
    end
    assert build(key: "mobile-phone", value: "13032222113").save, "a person's phone was refused (control)"
    assert build(key: "date-of-birth", value: "19960521").save, "a person's compact date was refused (control)"

    { "ein" => BANK_DIGITS, "business-phone" => "123456789", "fax" => "1234567890123456", "zip" => "12345678",
      "formed" => "12345678", "sos-id" => "1234567890123", "revenue" => "12500000" }.each do |key, value|
      assert_pointer_refusal(:value, "company #{key} with the wrong shape", key: key, value: value, **company)
    end
    assert_pointer_refusal(:value, "a person's duns", key: "duns", value: "123456789")
    assert_pointer_refusal(:value, "a nine-digit number beside the phone", key: "phone", value: "3032222113 and 123456789")
  end

  test "[unit] the columns stored in the clear pass the same screen: source reference, note and subject slug" do
    assert_pointer_refusal(:source_ref, "an ssn as the reference", digits: SSN_DIGITS, source_ref: "ssn #{SSN_DIGITS}")
    assert_pointer_refusal(:source_ref, "a long number as the reference", digits: BANK_DIGITS, source_ref: BANK_DIGITS)
    assert_pointer_refusal(:source_note, "a long number in the note", digits: BANK_DIGITS, source_note: "wire to #{BANK_DIGITS}")
    assert_pointer_refusal(:source_note, "a password in the note", source_note: "password: hunter2!")
    assert_pointer_refusal(:subject_slug, "an ssn as a company slug", subject_type: "company", subject_slug: SSN_DIGITS)
    assert_pointer_refusal(:subject_slug, "digits as a company slug", subject_type: "company", subject_slug: "co-1234-5678-90")
    assert_equal 0, Fact.count

    assert build(source_kind: "drive_file", source_ref: "1AbCdEf9012xYz-34_QrsT5678uvW9a0BcD", source_note: "page 2, 2026-10-07").save
    assert build(source_ref: "4812", subject_type: "company", subject_slug: "acme-welding-2020").save
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

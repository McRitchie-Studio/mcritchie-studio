# frozen_string_literal: true

# [unit] + [integration] AppleContact — the helper that writes a signature into
# the operator's Apple Contacts (bin/apple-contact, docs/agents/modules/contact-capture.md).
#
# The unit tier covers the pure half: normalizing the card an agent read,
# matching it against the address book, and the diff the operator is asked
# about. The integration tier runs the REAL bin/apple-contact against a fake
# `osascript` on PATH that records its argv, because the property that matters
# most — a signature value reaches Contacts as data, never as script — is a
# property of the command line, and only a recorded command line can show it.
# Nothing here touches the real Contacts app.
#
#   ruby -Itest test/lib/apple_contact_test.rb

require "minitest/autorun"
require "tmpdir"
require "json"
require "open3"
require "rbconfig"
require_relative "../../bin/lib/apple_contact"

class AppleContactTest < Minitest::Test
  SIGNATURE = {
    "first_name" => "Pat", "last_name" => "Example", "organization" => "Example Title Co",
    "job_title" => "Escrow Officer",
    "phones" => [ { "label" => "direct", "value" => "303.555.0101" }, { "label" => "work", "value" => "303.555.0102" } ],
    "emails" => [ { "label" => "work", "value" => "Pat.Example@example.com" } ],
    "urls" => [ "https://www.example.com/" ],
    "addresses" => [ { "label" => "work", "street" => "1 Main St. #100", "city" => "Denver", "state" => "CO", "zip" => "80206" } ],
    "note" => "License #000001"
  }.freeze

  # A signature is attacker-influenced text. This one closes an AppleScript
  # string and calls `do shell script`, and closes a JS string and calls into
  # another app. It must arrive in Contacts as exactly these characters.
  HOSTILE = %q{" & (do shell script "touch /tmp/owned") & " "); Application('Finder').quit(); ("}

  def card(overrides = {}) = AppleContact.normalize(SIGNATURE.merge(overrides))

  # --- normalize -------------------------------------------------------------

  def test_normalize_fills_labels_and_accepts_bare_strings
    c = card

    assert_equal({ "label" => "work", "value" => "https://www.example.com/" }, c["urls"].first,
                 "a bare string becomes a work-labelled entry")
    assert_equal "direct", c["phones"].first["label"]
    assert_equal "80206", c["addresses"].first["zip"]
  end

  def test_normalize_refuses_an_unknown_field_rather_than_dropping_it
    err = assert_raises(AppleContact::Error) { AppleContact.normalize(SIGNATURE.merge("phone" => "303")) }

    assert_match(/unknown contact field.*phone/, err.message,
                 "a typo'd key that vanished would read as 'the signature had no phone'")
  end

  def test_normalize_refuses_a_card_with_no_name_and_no_company
    assert_raises(AppleContact::Error) { AppleContact.normalize("emails" => [ "a@example.com" ]) }
  end

  def test_normalize_drops_blank_entries
    c = card("phones" => [ { "value" => "  " } ], "addresses" => [ { "street" => "" } ])

    assert_empty c["phones"]
    assert_empty c["addresses"]
  end

  # --- comparison keys -------------------------------------------------------

  def test_every_spelling_of_one_phone_number_compares_equal
    keys = [ "303.555.0101", "(303) 555-0101", "+1 303 555 0101", "1-303-555-0101", "3035550101" ].map { |v| AppleContact.phone_key(v) }

    assert_equal [ "3035550101" ], keys.uniq
  end

  def test_urls_and_emails_compare_without_case_scheme_or_trailing_slash
    assert_equal AppleContact.url_key("https://www.Example.com/"), AppleContact.url_key("example.com")
    assert_equal AppleContact.email_key(" Pat.Example@EXAMPLE.com"), AppleContact.email_key("pat.example@example.com")
  end

  # --- matching --------------------------------------------------------------

  def snapshot
    [
      { "id" => "A", "first_name" => "Pat", "last_name" => "Example", "organization" => "Example Title Co",
        "emails" => [ "pat.example@example.com" ], "phones" => [ "(303) 555-0101" ] },
      { "id" => "B", "first_name" => "Pat", "last_name" => "Other", "organization" => nil, "emails" => [], "phones" => [ "303-555-0102" ] },
      { "id" => "C", "first_name" => "Pat", "last_name" => "Example", "organization" => "Somewhere Else", "emails" => [], "phones" => [] },
      { "id" => "D", "first_name" => "Lee", "last_name" => nil, "organization" => nil, "emails" => [], "phones" => [ "555-0101" ] },
      { "id" => "E", "first_name" => nil, "last_name" => nil, "organization" => "Unrelated", "emails" => nil, "phones" => nil }
    ]
  end

  def test_matches_rank_by_how_many_reasons_agree_and_say_why
    found = AppleContact.matches(card, snapshot)

    assert_equal %w[A B C], found.map { |m| m["id"] }
    assert_equal [ "email pat.example@example.com", "phone (303) 555-0101", "name" ], found.first["reasons"]
    assert_equal [ "phone 303-555-0102" ], found[1]["reasons"], "a shared office line is offered, with its reason"
    assert_equal [ "name" ], found[2]["reasons"], "a namesake is offered so the operator can say it is someone else"
  end

  def test_a_first_name_alone_never_matches_by_name
    found = AppleContact.matches(card("last_name" => "", "phones" => [], "emails" => []), snapshot)

    assert_empty found, "every Pat in the book is not a match for a signature that only says Pat"
  end

  # --- diff ------------------------------------------------------------------

  def existing
    {
      "first_name" => "Pat", "last_name" => "Example", "organization" => "Old Title Co", "job_title" => "",
      "note" => "met at closing",
      "phones" => [ { "label" => "mobile", "value" => "(303) 555-0101" }, { "label" => "home", "value" => "720-555-0199" } ],
      "emails" => [ { "label" => "work", "value" => "pat.example@example.com" } ],
      "urls" => [],
      "addresses" => [ { "label" => "work", "street" => "1 Main St #100", "city" => "Denver", "state" => "CO", "zip" => "80206" } ]
    }
  end

  def row(rows, field, signature: nil, card: nil)
    rows.find { |r| r["field"] == field && (signature.nil? || r["signature"] == signature) && (card.nil? || r["card"] == card) }
  end

  def test_diff_names_every_discrepancy_and_what_update_would_do
    rows = AppleContact.diff(card, existing)

    assert_equal "same", row(rows, "first_name")["action"]
    assert_equal({ "field" => "organization", "action" => "change", "card" => "Old Title Co", "signature" => "Example Title Co" },
                 row(rows, "organization"))
    assert_equal "add", row(rows, "job_title")["action"], "a blank field on the card is an add, not a change"

    same_phone = row(rows, "phones", signature: "303.555.0101")
    assert_equal "same", same_phone["action"]
    assert_equal "(303) 555-0101", same_phone["card"], "a same row shows the card's own spelling"
    assert_equal "add", row(rows, "phones", signature: "303.555.0102")["action"]
    assert_equal "keep", row(rows, "phones", card: "720-555-0199")["action"], "a value only the card holds is never removed"

    assert_equal "same", row(rows, "emails")["action"]
    assert_equal "add", row(rows, "urls")["action"]
    assert_equal "same", row(rows, "addresses")["action"], "'St.' and 'St' with one zip are one address"
    assert_equal "add", row(rows, "note")["action"]
  end

  def test_patch_carries_only_add_and_change_rows_minus_skipped_fields
    patch = AppleContact.patch(card, existing, skip: [ "organization" ])

    assert_equal({ "job_title" => "Escrow Officer" }, patch["scalars"], "the skipped company stays as the card has it")
    assert_equal [ "303.555.0102" ], patch["phones"].map { |e| e["value"] }
    assert_empty patch["emails"]
    assert_empty patch["addresses"]
    assert_equal "License #000001", patch["note"]
  end

  def test_a_card_that_already_agrees_yields_an_empty_patch
    assert AppleContact.empty_patch?(AppleContact.patch(card, AppleContact.normalize(SIGNATURE).merge(
      "phones" => card["phones"], "emails" => card["emails"], "urls" => card["urls"],
      "addresses" => card["addresses"], "note" => "License #000001"
    )))
  end

  # --- the programs are constants --------------------------------------------

  def test_no_program_can_interpolate_a_value
    [ AppleContact::SNAPSHOT_JS, AppleContact::DETAIL_JS, AppleContact::CREATE_JS,
      AppleContact::UPDATE_JS, AppleContact::PHOTO_APPLESCRIPT ].each do |program|
      assert program.frozen?, "a program must be a frozen constant"
      refute_includes program, "\#{", "a program built at load time carries no Ruby interpolation"
    end
    [ AppleContact::SNAPSHOT_JS, AppleContact::DETAIL_JS, AppleContact::CREATE_JS, AppleContact::UPDATE_JS ].each do |program|
      assert_includes program, "JSON.parse(argv[0])", "a JXA program reads its payload from argv"
    end
  end

  # --- integration: the real CLI against a fake osascript --------------------

  # The fake records every argv as one JSON line, answers by which program it
  # was handed, and — when FAKE_TIMEOUT_UNTIL_ACTIVATE is set — fails with the
  # measured -1712 until the payload asks for `activate`.
  FAKE = <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    File.open(ENV.fetch("FAKE_LOG"), "a") { |f| f.puts(JSON.generate(ARGV)) }
    program = ARGV[ARGV.index("-e") + 1]
    payload = JSON.parse(ARGV.last)
    if ENV["FAKE_TIMEOUT_UNTIL_ACTIVATE"] && !payload["activate"]
      warn "execution error: Contacts got an error: AppleEvent timed out. (-1712)"
      exit 1
    end
    fixtures = JSON.parse(File.read(ENV.fetch("FAKE_FIXTURES")))
    answer =
      if program.include?("C.Person(props)") then { "id" => "NEW:ABPerson" }
      elsif program.include?("p[k] = input.scalars[k]") then { "id" => payload["id"] }
      elsif program.include?("byId(input.id)") then fixtures.fetch("detail").fetch(payload["id"])
      else fixtures.fetch("snapshot")
      end
    puts JSON.generate(answer)
  RUBY

  BIN = File.expand_path("../../bin/apple-contact", __dir__)

  def with_fake(fixtures, env: {})
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "osascript")
      File.write(fake, FAKE)
      File.chmod(0o755, fake)
      File.write(File.join(dir, "fixtures.json"), JSON.generate(fixtures))
      log = File.join(dir, "argv.log")
      File.write(log, "")
      base = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "FAKE_LOG" => log, "FAKE_FIXTURES" => File.join(dir, "fixtures.json") }
      run = lambda do |*args, card: nil|
        if card
          path = File.join(dir, "card.json")
          File.write(path, JSON.generate(card))
          args += [ "--file", path ]
        end
        Open3.capture3(base.merge(env), RbConfig.ruby, BIN, *args)
      end
      yield run, -> { File.readlines(log).map { |l| JSON.parse(l) } }
    end
  end

  EMPTY_BOOK = { "snapshot" => [], "detail" => {} }.freeze

  def test_create_hands_osascript_the_constant_program_and_the_values_only_as_json_argv
    with_fake(EMPTY_BOOK) do |run, calls|
      out, err, status = run.call("create", card: SIGNATURE.merge("note" => HOSTILE, "job_title" => HOSTILE))

      assert status.success?, err
      assert_equal "NEW:ABPerson", JSON.parse(out)["created"]

      create = calls.call.find { |argv| argv.include?(AppleContact::CREATE_JS) }
      refute_nil create, "osascript must receive CREATE_JS byte-for-byte — no value spliced into the program"
      assert_equal [ "-l", "JavaScript", "-e", AppleContact::CREATE_JS ], create.first(4)
      assert_equal 5, create.size, "the payload is ONE argv string after the program"

      payload = JSON.parse(create.last)
      assert_equal HOSTILE, payload["note"], "the hostile note travels as data, unchanged"
      assert_equal HOSTILE, payload["scalars"]["jobTitle"]
      assert_equal "Pat", payload["scalars"]["firstName"], "scalars arrive in Contacts' own property names"
      calls.call.each do |argv|
        program = argv[argv.index("-e") + 1]
        refute_includes program, "do shell script", "no program osascript ran contains the signature's text"
      end
    end
  end

  def test_create_refuses_when_a_card_already_matches
    book = { "snapshot" => [ { "id" => "A", "first_name" => "Pat", "last_name" => "Example", "emails" => [ "pat.example@example.com" ], "phones" => [] } ],
             "detail" => {} }
    with_fake(book) do |run, calls|
      _, err, status = run.call("create", card: SIGNATURE)

      refute status.success?
      assert_match(/already match.*Pat Example: email pat\.example@example\.com, name/, err)
      refute calls.call.any? { |argv| argv.include?(AppleContact::CREATE_JS) }, "nothing was written"

      _, err, status = run.call("create", "--allow-duplicate", card: SIGNATURE)
      assert status.success?, err
    end
  end

  def test_find_returns_each_match_with_its_diff
    book = { "snapshot" => [ { "id" => "A", "first_name" => "Pat", "last_name" => "Example", "emails" => [], "phones" => [ "303-555-0101" ] } ],
             "detail" => { "A" => existing.merge("id" => "A", "has_image" => false) } }
    with_fake(book) do |run, _|
      out, err, status = run.call("find", card: SIGNATURE)

      assert status.success?, err
      matches = JSON.parse(out)["matches"]
      assert_equal 1, matches.size
      match = matches.first
      assert_equal [ "phone 303-555-0101", "name" ], match["reasons"]
      assert_equal "change", match["diff"].find { |r| r["field"] == "organization" }["action"]
      refute match["has_image"]
    end
  end

  def test_update_sends_only_the_approved_patch
    book = { "snapshot" => [], "detail" => { "A" => existing.merge("id" => "A") } }
    with_fake(book) do |run, calls|
      out, err, status = run.call("update", "--id", "A", "--skip", "organization", "--skip", "note", card: SIGNATURE)

      assert status.success?, err
      assert_equal %w[job_title phones urls], JSON.parse(out)["applied"].sort
      payload = JSON.parse(calls.call.find { |argv| argv.include?(AppleContact::UPDATE_JS) }.last)
      assert_equal({ "jobTitle" => "Escrow Officer" }, payload["scalars"])
      assert_nil payload["note"], "a skipped note is not appended"
    end
  end

  def test_update_with_nothing_to_change_writes_nothing
    agreeing = existing.merge("organization" => "Example Title Co", "job_title" => "Escrow Officer", "note" => "License #000001",
                              "phones" => SIGNATURE["phones"], "urls" => [ { "label" => "work", "value" => "example.com" } ])
    with_fake({ "snapshot" => [], "detail" => { "A" => agreeing } }) do |run, calls|
      out, err, status = run.call("update", "--id", "A", card: SIGNATURE)

      assert status.success?, err
      assert_empty JSON.parse(out)["applied"]
      refute calls.call.any? { |argv| argv.include?(AppleContact::UPDATE_JS) }
    end
  end

  def test_a_timed_out_contacts_is_retried_once_brought_to_the_front
    with_fake(EMPTY_BOOK, env: { "FAKE_TIMEOUT_UNTIL_ACTIVATE" => "1" }) do |run, calls|
      _, err, status = run.call("create", card: SIGNATURE)

      assert status.success?, err
      activations = calls.call.map { |argv| JSON.parse(argv.last)["activate"] }
      assert_equal [ false, true, true ], activations, "a read retries once with activate; the write runs once, activated"
      assert_equal 1, calls.call.count { |argv| argv.include?(AppleContact::CREATE_JS) }, "a write is never retried"
    end
  end

  def test_the_cli_refuses_what_it_cannot_account_for
    with_fake(EMPTY_BOOK) do |run, calls|
      _, _, status = run.call("create", "stray", card: SIGNATURE)
      refute status.success?, "a stray positional refuses"

      _, err, status = run.call("update", "--id", "A", "--skip", "phone", card: SIGNATURE)
      refute status.success?
      assert_match(/--skip names unknown field/, err)

      out, _, status = run.call("create", "--help")
      assert status.success?
      assert_match(/usage: bin\/apple-contact/, out)

      assert_empty calls.call, "none of those reached osascript"
    end
  end
end

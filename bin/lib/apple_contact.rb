# frozen_string_literal: true

require "json"
require "open3"
require "set"
require "tmpdir"

# AppleContact — find, create and update a card in the operator's Apple
# Contacts from a signature an agent read out of a forwarded email. The SOP that
# drives it is docs/agents/modules/contact-capture.md; this file is the only
# thing that writes to Contacts.
#
# ============================================================================
# THE INVARIANT THIS MODULE EXISTS FOR:
#
#     A VALUE FROM AN EMAIL REACHES CONTACTS AS DATA, NEVER AS SCRIPT.
#
# Every value here came out of a stranger's email signature, and AppleScript can
# run `do shell script`. A card built by interpolating "Pat" into an
# AppleScript string is a card built by interpolating `" & (do shell script
# "…") & "` the day a signature carries one. So the JXA programs below are
# FROZEN CONSTANTS with no interpolation, and the payload travels as a single
# JSON argv string that the program JSON.parse-s. The suite asserts the program
# text osascript receives is byte-identical to the constant.
# ============================================================================
#
# TWO MEASURED BEHAVIOURS (2026-09-28, macOS 26, 561 cards):
#
#   1. Contacts can sit on an Apple event until it is brought to the front: a
#      bare `count people` timed out three times running (-1712) and answered in
#      under a second once the app was activated. `Runner` therefore times out
#      fast and retries a READ once with `activate`; a write starts activated.
#   2. A card written by script can be missing from an open Contacts window
#      while it is already on the operator's iPhone; quitting and reopening the
#      app shows it. That is a stale window, not a failed save — `verify` reads
#      the card back from the store rather than trusting the window.
#
# It never deletes a card and never removes a value from one: `update` adds
# missing phones, emails, URLs and addresses, sets the name, company and title
# fields the operator approved, and APPENDS to the note.
module AppleContact
  class Error < StandardError; end

  SCALARS = %w[first_name last_name organization job_title].freeze
  MULTI   = %w[phones emails urls].freeze
  ADDRESS_KEYS = %w[street city state zip country].freeze
  KEYS = (SCALARS + MULTI + %w[addresses note]).freeze

  # Contacts' own property name for each scalar, in JXA spelling.
  JXA_SCALARS = {
    "first_name"   => "firstName",
    "last_name"    => "lastName",
    "organization" => "organization",
    "job_title"    => "jobTitle"
  }.freeze

  # ---------------------------------------------------------------------------
  # The card an agent read from a signature, normalized. Unknown keys are
  # refused rather than dropped: a typo'd "phone" that silently vanished would
  # read as "that signature had no phone".
  # ---------------------------------------------------------------------------
  def self.normalize(hash)
    raise Error, "a contact must be a JSON object" unless hash.is_a?(Hash)

    unknown = hash.keys.map(&:to_s) - KEYS
    raise Error, "unknown contact field(s): #{unknown.join(', ')} (known: #{KEYS.join(', ')})" if unknown.any?

    h = hash.transform_keys(&:to_s)
    card = {}
    SCALARS.each { |k| card[k] = clean(h[k]) }
    card["note"] = clean(h["note"])
    MULTI.each do |k|
      card[k] = Array(h[k]).map { |e| labelled(e, k) }.reject { |e| e["value"].empty? }
    end
    card["addresses"] = Array(h["addresses"]).map { |a| address(a) }.reject { |a| ADDRESS_KEYS.all? { |k| a[k].empty? } }

    if card["first_name"].empty? && card["last_name"].empty? && card["organization"].empty?
      raise Error, "a contact needs a first name, last name or organization"
    end

    card
  end

  def self.clean(value) = value.to_s.strip

  def self.labelled(entry, kind)
    entry = { "value" => entry } unless entry.is_a?(Hash)
    entry = entry.transform_keys(&:to_s)
    { "label" => clean(entry["label"]).then { |l| l.empty? ? "work" : l }, "value" => clean(entry["value"]) }
  rescue NoMethodError
    raise Error, "#{kind} entries must be strings or {label, value} objects"
  end

  def self.address(entry)
    raise Error, "addresses entries must be objects" unless entry.is_a?(Hash)

    entry = entry.transform_keys(&:to_s)
    a = { "label" => clean(entry["label"]).then { |l| l.empty? ? "work" : l } }
    ADDRESS_KEYS.each { |k| a[k] = clean(entry[k]) }
    a
  end

  # ---------------------------------------------------------------------------
  # Comparison keys. Two spellings of one phone number — "303.555.0101",
  # "(303) 555-0101", "+1 303 555 0101" — must compare equal, or every card with
  # a formatted number would read as a discrepancy.
  # ---------------------------------------------------------------------------
  def self.phone_key(value)
    digits = value.to_s.gsub(/\D/, "")
    digits = digits[1..] if digits.length == 11 && digits.start_with?("1")
    digits
  end

  def self.email_key(value) = value.to_s.strip.downcase

  def self.url_key(value) = value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").sub(/\Awww\./, "").chomp("/")

  def self.name_key(first, last) = [ first, last ].map { |s| s.to_s.strip.downcase }.join(" ").strip

  def self.address_key(a)
    street = a["street"].to_s.downcase.gsub(/[^a-z0-9]/, "")
    zip = a["zip"].to_s[/\d{5}/].to_s
    "#{street}|#{zip}"
  end

  MULTI_KEY = { "phones" => :phone_key, "emails" => :email_key, "urls" => :url_key }.freeze

  # ---------------------------------------------------------------------------
  # Matching. The snapshot is every card's id, name, organization, emails and
  # phones (one JXA read, ~0.4s for 561 cards). A card matches on an email, a
  # phone, or its full name; the reasons are returned so the operator sees WHY
  # a card was offered — two people with one first name at one company is a real case.
  # ---------------------------------------------------------------------------
  def self.matches(card, snapshot)
    emails = card["emails"].map { |e| email_key(e["value"]) }.to_set
    phones = card["phones"].map { |e| phone_key(e["value"]) }.reject { |p| p.length < 7 }.to_set
    name = name_key(card["first_name"], card["last_name"])

    snapshot.filter_map do |row|
      reasons = []
      hit_email = Array(row["emails"]).map { |v| email_key(v) }.find { |v| emails.include?(v) }
      reasons << "email #{hit_email}" if hit_email
      hit_phone = Array(row["phones"]).find { |v| phones.include?(phone_key(v)) }
      reasons << "phone #{hit_phone}" if hit_phone
      reasons << "name" if !name.empty? && name.include?(" ") && name_key(row["first_name"], row["last_name"]) == name
      next if reasons.empty?

      { "id" => row["id"], "name" => [ row["first_name"], row["last_name"] ].compact.join(" ").strip,
        "organization" => row["organization"].to_s, "reasons" => reasons }
    end.sort_by { |m| -m["reasons"].size }
  end

  # ---------------------------------------------------------------------------
  # The diff between what the signature says and what the card holds. Each row
  # is one thing the operator is asked about:
  #
  #   add     — the card lacks it; `update` will add it
  #   change  — the card holds a different value; `update` will replace it
  #   same    — nothing to do
  #   keep    — on the card, not in the signature; never removed
  #
  # A row is advisory until the operator answers. `update` applies add/change
  # rows only, and only those the caller did not `--skip`.
  # ---------------------------------------------------------------------------
  def self.diff(card, existing)
    rows = []

    SCALARS.each do |k|
      want = card[k]
      have = existing[k].to_s
      next if want.empty?

      action = if have.empty? then "add" elsif have.casecmp?(want) then "same" else "change" end
      rows << { "field" => k, "action" => action, "card" => have, "signature" => want }
    end

    MULTI.each do |k|
      key = method(MULTI_KEY.fetch(k))
      have = Array(existing[k])
      have_keys = have.map { |e| key.call(e["value"]) }
      want_keys = card[k].map { |e| key.call(e["value"]) }

      card[k].each_with_index do |e, i|
        at = have_keys.index(want_keys[i])
        rows << { "field" => k, "action" => at ? "same" : "add", "label" => e["label"],
                  "card" => at ? have[at]["value"].to_s : "", "signature" => e["value"] }
      end
      have.each_with_index do |e, i|
        next if want_keys.include?(have_keys[i])

        rows << { "field" => k, "action" => "keep", "label" => e["label"], "card" => e["value"], "signature" => "" }
      end
    end

    have_addresses = Array(existing["addresses"])
    card["addresses"].each do |a|
      same = have_addresses.find { |h| address_key(h) == address_key(a) }
      rows << { "field" => "addresses", "action" => same ? "same" : "add", "label" => a["label"],
                "card" => same ? format_address(same) : "", "signature" => format_address(a) }
    end
    have_addresses.each do |h|
      next if card["addresses"].any? { |a| address_key(a) == address_key(h) }

      rows << { "field" => "addresses", "action" => "keep", "label" => h["label"], "card" => format_address(h), "signature" => "" }
    end

    unless card["note"].empty?
      have = existing["note"].to_s
      rows << { "field" => "note", "action" => have.include?(card["note"]) ? "same" : "add",
                "card" => have, "signature" => card["note"] }
    end

    rows
  end

  def self.format_address(a)
    [ a["street"], [ a["city"], a["state"] ].map(&:to_s).reject(&:empty?).join(", "), a["zip"] ]
      .map(&:to_s).reject(&:empty?).join(" ")
  end

  # The update payload `update` sends: only add/change rows, minus skipped fields.
  def self.patch(card, existing, skip: [])
    rows = diff(card, existing).select { |r| %w[add change].include?(r["action"]) && !skip.include?(r["field"]) }
    patch = { "scalars" => {}, "phones" => [], "emails" => [], "urls" => [], "addresses" => [], "note" => nil }

    rows.each do |r|
      case r["field"]
      when *SCALARS then patch["scalars"][r["field"]] = r["signature"]
      when *MULTI then patch[r["field"]] << card[r["field"]].find { |e| e["value"] == r["signature"] }
      when "addresses" then patch["addresses"] << card["addresses"].find { |a| format_address(a) == r["signature"] }
      when "note" then patch["note"] = r["signature"]
      end
    end
    patch
  end

  def self.empty_patch?(patch)
    patch["scalars"].empty? && patch["note"].nil? && (MULTI + %w[addresses]).all? { |k| patch[k].empty? }
  end

  # ---------------------------------------------------------------------------
  # The JXA programs. FROZEN, NO INTERPOLATION — see the invariant at the top.
  # Each takes one argv string: JSON with the payload plus `activate`.
  # ---------------------------------------------------------------------------
  PRELUDE = <<~JS
    const input = JSON.parse(argv[0]);
    const C = Application("Contacts");
    if (input.activate) { C.activate(); } else { C.launch(); }
  JS

  SNAPSHOT_JS = <<~JS.freeze
    function run(argv) {
      #{PRELUDE}
      const p = C.people;
      const ids = p.id(), first = p.firstName(), last = p.lastName(), org = p.organization();
      const emails = p.emails.value(), phones = p.phones.value();
      return JSON.stringify(ids.map((id, i) => ({
        id: id, first_name: first[i], last_name: last[i], organization: org[i],
        emails: emails[i], phones: phones[i]
      })));
    }
  JS

  DETAIL_JS = <<~JS.freeze
    function run(argv) {
      #{PRELUDE}
      const p = C.people.byId(input.id);
      const multi = (list) => list().map((e) => ({ label: e.label(), value: e.value() }));
      return JSON.stringify({
        id: p.id(), first_name: p.firstName(), last_name: p.lastName(), organization: p.organization(),
        job_title: p.jobTitle(), note: p.note(),
        phones: multi(p.phones), emails: multi(p.emails), urls: multi(p.urls),
        addresses: p.addresses().map((a) => ({ label: a.label(), street: a.street(), city: a.city(),
          state: a.state(), zip: a.zip(), country: a.country() })),
        has_image: p.image() !== null
      });
    }
  JS

  # Shared by create and update: push each multi-value and address onto a card.
  WRITE_HELPERS = <<~JS
    const addAll = (p, patch) => {
      (patch.phones || []).forEach((e) => p.phones.push(C.Phone({ label: e.label, value: e.value })));
      (patch.emails || []).forEach((e) => p.emails.push(C.Email({ label: e.label, value: e.value })));
      (patch.urls || []).forEach((e) => p.urls.push(C.Url({ label: e.label, value: e.value })));
      (patch.addresses || []).forEach((a) => p.addresses.push(C.Address({ label: a.label, street: a.street,
        city: a.city, state: a.state, zip: a.zip, country: a.country })));
    };
  JS

  CREATE_JS = <<~JS.freeze
    function run(argv) {
      #{PRELUDE}
      #{WRITE_HELPERS}
      const props = {};
      Object.keys(input.scalars).forEach((k) => { if (input.scalars[k]) props[k] = input.scalars[k]; });
      if (input.note) props.note = input.note;
      const p = C.Person(props);
      C.people.push(p);
      addAll(p, input);
      C.save();
      return JSON.stringify({ id: p.id() });
    }
  JS

  UPDATE_JS = <<~JS.freeze
    function run(argv) {
      #{PRELUDE}
      #{WRITE_HELPERS}
      const p = C.people.byId(input.id);
      Object.keys(input.scalars).forEach((k) => { p[k] = input.scalars[k]; });
      if (input.note) {
        const had = p.note() || "";
        p.note = had ? had + "\\n" + input.note : input.note;
      }
      addAll(p, input);
      C.save();
      return JSON.stringify({ id: p.id() });
    }
  JS

  # The image travels as a PATH in the payload and is read by the program.
  # JXA cannot build the picture type Contacts wants, so this one is
  # AppleScript — still a frozen constant, still argv-only.
  PHOTO_APPLESCRIPT = <<~APPLESCRIPT.freeze
    on run argv
      set theId to item 1 of argv
      set imgPath to item 2 of argv
      set doActivate to item 3 of argv
      set imgData to read (POSIX file imgPath) as TIFF picture
      tell application "Contacts"
        if doActivate is "1" then activate
        set image of (person id theId) to imgData
        save
      end tell
      return theId
    end run
  APPLESCRIPT

  def self.jxa_scalars(card)
    JXA_SCALARS.to_h { |k, jxa| [ jxa, card[k].to_s ] }
  end

  # ---------------------------------------------------------------------------
  # Runner — the one door to osascript. Tests swap it for a recorder.
  # ---------------------------------------------------------------------------
  class Runner
    TIMEOUT = 20

    def initialize(timeout: TIMEOUT, osascript: "osascript")
      @timeout = timeout
      @osascript = osascript
    end

    # Runs a JXA program, payload as its one argv string; returns parsed JSON. A
    # read retries once activated (measured behaviour 1). A write runs ONCE,
    # activated: an unanswered event can still land, so a retry could duplicate.
    def jxa(program, payload, write: false)
      out = attempt([ @osascript, "-l", "JavaScript", "-e", program, JSON.generate(payload.merge("activate" => false)) ]) unless write
      out ||= attempt([ @osascript, "-l", "JavaScript", "-e", program, JSON.generate(payload.merge("activate" => true)) ], last: true)
      JSON.parse(out)
    rescue JSON::ParserError
      raise Error, "Contacts answered with something that is not JSON"
    end

    # Only `photo` uses this, and it writes: one activated attempt, no retry.
    def applescript(program, *args) = attempt([ @osascript, "-e", program, *args, "1" ], last: true)

    private

    def attempt(cmd, last: false)
      stdout, stderr, status = capture(cmd)
      return stdout.strip if status&.success?

      retryable = status.nil? || stderr.include?("-1712")
      raise Error, failure(stderr, status) if last || !retryable

      nil
    end

    def capture(cmd)
      Open3.popen3(*cmd) do |stdin, out, err, thread|
        stdin.close
        reader = Thread.new { [ out.read, err.read ] }
        unless thread.join(@timeout)
          Process.kill("TERM", thread.pid) rescue nil
          thread.join
          return [ "", "timed out after #{@timeout}s", nil ]
        end
        stdout, stderr = reader.value
        [ stdout, stderr, thread.value ]
      end
    rescue Errno::ENOENT
      raise Error, "#{@osascript} not found — this helper runs on the operator's Mac only"
    end

    def failure(stderr, status)
      if stderr.include?("-1743") || stderr.include?("Not authorized")
        "macOS refused access to Contacts. Allow this terminal under System Settings → Privacy & Security → " \
          "Automation (and Contacts), then retry."
      elsif status.nil? || stderr.include?("-1712")
        "Contacts did not answer, even after being brought to the front. Open Contacts, dismiss any dialog, and retry."
      else
        "osascript failed: #{stderr.strip}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The operations the CLI exposes.
  # ---------------------------------------------------------------------------
  class Book
    def initialize(runner: Runner.new)
      @runner = runner
    end

    def snapshot = @runner.jxa(SNAPSHOT_JS, {})

    def detail(id) = @runner.jxa(DETAIL_JS, { "id" => id })

    # Every card that shares an email, a phone or the full name, each with the
    # diff the operator is asked about.
    def find(card)
      AppleContact.matches(card, snapshot).map do |m|
        existing = detail(m["id"])
        m.merge("has_image" => existing["has_image"], "diff" => AppleContact.diff(card, existing))
      end
    end

    def create(card, allow_duplicate: false)
      found = AppleContact.matches(card, snapshot)
      if found.any? && !allow_duplicate
        raise Error, "#{found.size} existing card(s) already match (#{found.map { |m| "#{m['name']}: #{m['reasons'].join(', ')}" }.join('; ')}). " \
                     "Use `update --id`, or pass --allow-duplicate if the operator chose a separate card."
      end

      payload = { "scalars" => AppleContact.jxa_scalars(card), "note" => card["note"] }
      (AppleContact::MULTI + %w[addresses]).each { |k| payload[k] = card[k] }
      @runner.jxa(CREATE_JS, payload, write: true).fetch("id")
    end

    def update(id, card, skip: [])
      patch = AppleContact.patch(card, detail(id), skip: skip)
      return { "id" => id, "applied" => [] } if AppleContact.empty_patch?(patch)

      payload = patch.merge("id" => id, "scalars" => patch["scalars"].to_h { |k, v| [ JXA_SCALARS.fetch(k), v ] })
      @runner.jxa(UPDATE_JS, payload, write: true)
      { "id" => id, "applied" => applied_fields(patch) }
    end

    def photo(id, image)
      path = File.expand_path(image)
      raise Error, "no image at #{path}" unless File.file?(path)

      # Convert in a private temp dir, never beside the source, so no file of
      # the operator's is overwritten or deleted.
      Dir.mktmpdir("apple-contact") do |dir|
        tiff = File.join(dir, "photo.tiff")
        _, err, status = Open3.capture3("sips", "-s", "format", "tiff", path, "--out", tiff)
        raise Error, "sips could not convert #{path}: #{err.strip}" unless status.success?

        @runner.applescript(PHOTO_APPLESCRIPT, id, tiff)
      end
      id
    end

    private

    def applied_fields(patch)
      fields = patch["scalars"].keys
      (AppleContact::MULTI + %w[addresses]).each { |k| fields << k if patch[k].any? }
      fields << "note" if patch["note"]
      fields
    end
  end
end

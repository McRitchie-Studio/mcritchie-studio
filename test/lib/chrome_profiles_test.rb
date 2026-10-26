# frozen_string_literal: true

# [unit] ChromeProfiles — the Chrome avatar-menu roster and its resolver.
#
# WHAT THIS FILE IS FOR. The roster exists to survive a house burn-down, so the
# property that matters is not "it produced the right menu on the Mac it was
# written on" — it is "it produces the right menu on a DIFFERENT Mac, whose
# profile directories were handed out in a different order". Chrome assigns
# `Default`, `Profile 7`, `Profile 14` in SIGN-IN order; they are an accident of
# history and they are not even dense. A roster keyed on them does not fail
# loudly when restored — it renames the WRONG PROFILES, silently, and the
# operator finds out by opening a menu. test_the_same_roster_lands_on_two_
# machines_with_different_directories is the assertion that whole design exists
# for, and it is the one to fix first if it ever goes red.
#
# The refusals get equal weight, because a resolver that refuses nothing is
# indistinguishable from one that works right up until the day it is not.
#
#   ruby -Itest test/lib/chrome_profiles_test.rb

require "minitest/autorun"
require "minitest/mock"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/chrome_profiles"
require_relative "../../bin/lib/op_meter"

class ChromeProfilesTest < Minitest::Test
  include ChromeProfiles

  def setup
    @dir = Dir.mktmpdir("chrome-profiles-test")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A `Local State` as Chrome writes it. `dirs` maps a profile directory to
  # [account, display name, GAIA given name] so a test can hand the SAME accounts
  # to DIFFERENT directories, which is the whole point of the file.
  def local_state(dirs, order: nil, extra: {})
    cache = dirs.to_h do |dir, (account, name, gaia)|
      [ dir, { "user_name" => account, "name" => name, "gaia_given_name" => gaia,
               "gaia_id" => "id-#{dir}", "avatar_icon" => "chrome://theme/x" } ]
    end
    data = { "profile" => { "info_cache" => cache, "profiles_order" => order || dirs.keys }
      .merge(extra) }
    path = File.join(@dir, "Local State-#{cache.hash.abs}")
    File.write(path, JSON.generate(data))
    LocalState.load(path)
  end

  def roster(pairs)
    path = File.join(@dir, "roster-#{pairs.hash.abs}.yml")
    # SINGLE-quoted, because Ruby's String#inspect escapes an emoji to \u{1FA8E}
    # and YAML's DOUBLE-quoted scalar then tries to read that as a hex escape.
    body = pairs.map do |account, label|
      "  - account: #{account}\n    label: '#{label.gsub("'", "''")}'\n"
    end
    File.write(path, "profiles:\n#{body.join}")
    Roster.load(path)
  end

  # ---------------------------------------------------------------------------
  # Chrome's GetNameForm, reproduced
  # ---------------------------------------------------------------------------

  def test_menu_row_prepends_the_gaia_name_and_parenthesises_the_label
    profile = Profile.new(dir: "Profile 2", account: "a@b.c", name: "🪎 studio", gaia: "Alex")

    assert_equal "Alex (🪎 studio)", profile.menu_row
  end

  # This is how Margot and Mason get a bare row. It is not a special case in the
  # roster — it falls out of Chrome collapsing the two halves when they match.
  def test_menu_row_collapses_when_the_label_equals_the_gaia_name
    profile = Profile.new(dir: "Profile 5", account: "m@b.c", name: "Margot", gaia: "Margot")

    assert_equal "Margot", profile.menu_row
  end

  def test_menu_row_is_the_label_alone_when_chrome_has_no_gaia_name
    profile = Profile.new(dir: "Profile 9", account: "t@b.c", name: "Team", gaia: "")

    assert_equal "Team", profile.menu_row
  end

  # ---------------------------------------------------------------------------
  # THE INVARIANT — email keys, directories resolved at run time
  # ---------------------------------------------------------------------------

  # The assertion the whole design exists for. Same roster, two machines whose
  # sign-in order differed; the MENU must be identical and the DIRECTORIES must
  # not be. Delete the email keying and this is what goes red.
  def test_the_same_roster_lands_on_two_machines_with_different_directories
    wanted = roster([ [ "alex@studio.test", "🪎 studio" ],
                      [ "team@studio.test", "📐 industries" ],
                      [ "alex@turf.test",   "🐊 turf" ] ])

    original = local_state({
      "Profile 7"  => [ "alex@studio.test", "old", "Alex" ],
      "Profile 14" => [ "team@studio.test", "old", "Team" ],
      "Default"    => [ "alex@turf.test",   "old", "Alex" ]
    })
    # A rebuilt Mac signed in the other way round: same accounts, different dirs,
    # and NOT dense — exactly what Chrome does.
    rebuilt = local_state({
      "Default"   => [ "team@studio.test", "old", "Team" ],
      "Profile 1" => [ "alex@turf.test",   "old", "Alex" ],
      "Profile 3" => [ "alex@studio.test", "old", "Alex" ]
    })

    a = Plan.new(roster: wanted, state: original)
    b = Plan.new(roster: wanted, state: rebuilt)

    assert_empty a.refusals
    assert_empty b.refusals
    assert_equal [ "Alex (🪎 studio)", "Team (📐 industries)", "Alex (🐊 turf)" ],
                 a.menu.map(&:last)
    assert_equal a.menu.map(&:last), b.menu.map(&:last),
                 "the same roster produced a different MENU on a machine whose directories differ"
    assert_equal [ "Profile 7", "Profile 14", "Default" ], a.order
    assert_equal [ "Profile 3", "Default", "Profile 1" ], b.order
    refute_equal a.order, b.order,
                 "the fixtures no longer differ in directory assignment, so this test proves nothing"
  end

  # ---------------------------------------------------------------------------
  # The asymmetry: missing is normal, unlisted is a refusal
  # ---------------------------------------------------------------------------

  # Halfway through a rebuild you have signed into four of twelve accounts.
  # Refusing there would make the roster useless for the one job it exists to do.
  def test_a_roster_account_absent_from_the_machine_is_reported_not_refused
    wanted = roster([ [ "here@studio.test", "🪎 here" ], [ "gone@studio.test", "📐 gone" ] ])
    state = local_state({ "Default" => [ "here@studio.test", "old", "Alex" ] })

    plan = Plan.new(roster: wanted, state: state)

    assert_empty plan.refusals, "a not-yet-signed-in account must not block the rest"
    assert_equal [ "gone@studio.test" ], plan.missing
    assert_equal [ "Default" ], plan.order, "the resolvable row must still land"
  end

  # The guard that caught `Profile 14` minutes after Google created it. Renaming
  # and reordering a profile nobody declared is how the wrong account gets a
  # label, and dropping it from the order is how it disappears from the menu.
  def test_a_profile_on_the_machine_that_the_roster_omits_is_a_refusal
    wanted = roster([ [ "known@studio.test", "🪎 known" ] ])
    state = local_state({
      "Default"    => [ "known@studio.test",   "old", "Alex" ],
      "Profile 14" => [ "surprise@studio.test", "old", "Team" ]
    })

    plan = Plan.new(roster: wanted, state: state)

    assert plan.refuse?
    assert_match(/Profile 14 \(surprise@studio\.test\)/, plan.refusals.join("\n"))
  end

  def test_a_profile_signed_into_no_account_is_a_refusal_because_it_cannot_be_keyed
    wanted = roster([ [ "known@studio.test", "🪎 known" ] ])
    state = local_state({
      "Default"   => [ "known@studio.test", "old", "Alex" ],
      "Profile 2" => [ "",                  "Person 2", "" ]
    })

    plan = Plan.new(roster: wanted, state: state)

    assert plan.refuse?
    assert_match(/Profile 2 is signed into no account/, plan.refusals.join("\n"))
  end

  def test_the_same_account_listed_twice_in_the_roster_is_a_refusal
    wanted = roster([ [ "dup@studio.test", "🪎 one" ], [ "dup@studio.test", "📐 two" ] ])
    state = local_state({ "Default" => [ "dup@studio.test", "old", "Alex" ] })

    plan = Plan.new(roster: wanted, state: state)

    assert plan.refuse?
    assert_match(/lists dup@studio\.test more than once/, plan.refusals.join("\n"))
  end

  def test_two_profiles_sharing_one_account_is_a_refusal
    wanted = roster([ [ "same@studio.test", "🪎 one" ] ])
    state = local_state({
      "Default"   => [ "same@studio.test", "old", "Alex" ],
      "Profile 4" => [ "same@studio.test", "old", "Alex" ]
    })

    plan = Plan.new(roster: wanted, state: state)

    assert plan.refuse?
    assert_match(/two profiles share same@studio\.test/, plan.refusals.join("\n"))
  end

  # ---------------------------------------------------------------------------
  # Constraint 3, enforced instead of remembered
  # ---------------------------------------------------------------------------

  def test_a_label_repeating_the_prepended_name_is_refused_with_the_row_it_would_render
    wanted = roster([ [ "alex@studio.test", "Alex studio" ] ])
    state = local_state({ "Default" => [ "alex@studio.test", "old", "Alex" ] })

    plan = Plan.new(roster: wanted, state: state)

    assert plan.refuse?
    assert_match(/would render as "Alex \(Alex studio\)"/, plan.refusals.join("\n"))
  end

  # The OPPOSITE case, and the one a careless guard breaks: a label EQUAL to the
  # prepended name is how a row loses its parentheses entirely. Refusing it would
  # make `Margot` impossible to express.
  def test_a_label_equal_to_the_prepended_name_is_allowed
    wanted = roster([ [ "margot@studio.test", "Margot" ] ])
    state = local_state({ "Default" => [ "margot@studio.test", "old", "Margot" ] })

    plan = Plan.new(roster: wanted, state: state)

    assert_empty plan.refusals
    assert_equal [ "Margot" ], plan.menu.map(&:last)
  end

  def test_an_empty_label_is_refused
    wanted = roster([ [ "alex@studio.test", "" ] ])
    state = local_state({ "Default" => [ "alex@studio.test", "old", "Alex" ] })

    assert_match(/has an empty label/, Plan.new(roster: wanted, state: state).refusals.join("\n"))
  end

  # ---------------------------------------------------------------------------
  # Roster parsing
  # ---------------------------------------------------------------------------

  def test_accounts_are_downcased_so_a_capitalised_address_still_matches
    wanted = roster([ [ "Alex@Studio.TEST", "🪎 studio" ] ])
    state = local_state({ "Default" => [ "alex@studio.test", "old", "Alex" ] })

    assert_empty Plan.new(roster: wanted, state: state).refusals
  end

  def test_a_roster_entry_without_an_account_names_its_position
    path = File.join(@dir, "bad.yml")
    File.write(path, "profiles:\n  - label: \"no account\"\n")

    assert_match(/entry 1 has no `account:`/, assert_raises(Error) { Roster.load(path) }.message)
  end

  def test_a_file_with_no_profiles_list_is_rejected
    path = File.join(@dir, "empty.yml")
    File.write(path, "something_else: true\n")

    assert_match(/has no `profiles:` list/, assert_raises(Error) { Roster.load(path) }.message)
  end

  # ---------------------------------------------------------------------------
  # Where the roster comes from
  # ---------------------------------------------------------------------------
  #
  # The repo is PUBLIC and the roster keys on account email, so the real one
  # lives in 1Password and only a .example is committed. These pin the seam that
  # chooses between the two — and, more importantly, the ONE case that must never
  # be made friendly.

  def test_an_explicit_config_reads_the_file_and_never_asks_1password
    path = File.join(@dir, "explicit.yml")
    File.write(path, "profiles:\n  - account: a@studio.test\n    label: 'x'\n")

    called = false
    OpMeter.stub(:popen, ->(*) { called = true; "" }) do
      assert_equal [ "a@studio.test" ], Roster.resolve(config: path).accounts
    end
    refute called, "an explicit --config spent a 1Password read; the daily cap is account-wide"
  end

  def test_with_no_config_the_roster_comes_from_the_vault_document
    yaml = "profiles:\n  - account: vault@studio.test\n    label: 'from the vault'\n"

    OpMeter.stub(:popen, yaml) do
      roster = Roster.resolve(config: nil)

      assert_equal [ "vault@studio.test" ], roster.accounts
      assert_equal "op://#{ChromeProfiles.op_vault}/#{OP_ITEM}", roster.path,
                   "the source must name itself, so `status` cannot look identical for a file and the vault"
    end
  end

  def test_exactly_one_op_read_per_resolve
    reads = 0
    OpMeter.stub(:popen, ->(*) { reads += 1; "profiles:\n  - account: a@b.test\n    label: 'x'\n" }) do
      Roster.resolve(config: nil)
    end

    assert_equal 1, reads, "the 1Password daily cap is ACCOUNT-WIDE and shared with every other lane"
  end

  # THE ONE THAT MUST NEVER BE MADE FRIENDLY. Falling back to the committed
  # example would resolve placeholder addresses against a real machine: every
  # profile becomes unlisted, and the roster's own guard then refuses — loudly,
  # and for entirely the wrong reason. The operator would go hunting a profile
  # problem that does not exist.
  def test_an_unreachable_vault_refuses_rather_than_falling_back_to_the_example
    OpMeter.stub(:popen, "") do
      message = assert_raises(Error) { Roster.resolve(config: nil) }.message

      assert_match(/Could not read the roster from 1Password/, message)
      assert_match(/op service-account ratelimit/, message, "the remedy must name the shared quota")
      assert_match(/does NOT fall back/, message)
    end
  end

  def test_a_missing_op_binary_is_named_rather_than_raised_as_a_system_error
    OpMeter.stub(:popen, ->(*) { raise Errno::ENOENT, "op" }) do
      message = assert_raises(Error) { Roster.resolve(config: nil) }.message

      assert_match(/1Password CLI \(`op`\) is not installed/, message)
      assert_match(/op document create/, message, "it must say how to file the document")
    end
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  # Chrome's Local State also holds every OTHER browser preference. Writing the
  # whole document back is how a profile-menu edit silently drops an unrelated
  # setting, so the write is asserted to be surgical.
  def test_apply_sets_the_order_and_names_and_leaves_every_other_field_intact
    wanted = roster([ [ "b@studio.test", "🐊 turf" ], [ "a@studio.test", "🪎 studio" ] ])
    state = local_state(
      { "Default"   => [ "a@studio.test", "stale", "Alex" ],
        "Profile 1" => [ "b@studio.test", "stale", "Alex" ] },
      order: [ "Default", "Profile 1" ],
      extra: { "last_used" => "Profile 1" }
    )
    plan = Plan.new(roster: wanted, state: state)

    backup = Writer.apply!(state, plan)
    after = JSON.parse(File.read(state.path))

    assert_equal [ "Profile 1", "Default" ], after["profile"]["profiles_order"]
    assert_equal "🐊 turf", after["profile"]["info_cache"]["Profile 1"]["name"]
    assert_equal "🪎 studio", after["profile"]["info_cache"]["Default"]["name"]
    refute after["profile"]["info_cache"]["Default"]["is_using_default_name"]
    assert_equal "Profile 1", after["profile"]["last_used"], "an unrelated preference was dropped"
    assert_equal "id-Default", after["profile"]["info_cache"]["Default"]["gaia_id"],
                 "identity fields must never be rewritten"
    assert File.file?(backup), "no backup was taken before rewriting Chrome's own state"
  end

  def test_apply_refuses_a_plan_that_refuses_and_leaves_the_file_byte_identical
    wanted = roster([ [ "a@studio.test", "🪎 studio" ] ])
    state = local_state({ "Default"   => [ "a@studio.test", "stale", "Alex" ],
                          "Profile 8" => [ "unlisted@studio.test", "stale", "Admin" ] })
    before = File.read(state.path)

    assert_raises(Error) { Writer.apply!(state, Plan.new(roster: wanted, state: state)) }
    assert_equal before, File.read(state.path)
  end

  # ---------------------------------------------------------------------------
  # Emoji presence
  # ---------------------------------------------------------------------------
  #
  # Built from bytes rather than read from the system font, because the font is
  # macOS-only and CI runs on Ubuntu — a test that skips there would assert
  # nothing on the machine that gates the merge. The synthetic fonts below
  # exercise the real cmap parser: the TTC container, format 12, format 4, and
  # the wide-span rejection that keeps a misparse from answering "present" to
  # every codepoint you ask about.

  def format12(ranges)
    groups = ranges.map { |r| [ r.first, r.last, 1 ].pack("N3") }.join
    [ 12, 0 ].pack("n2") + [ 16 + groups.bytesize, 0, ranges.length ].pack("N3") + groups
  end

  def format4(segments)
    [ 4, 0, 0, segments.length * 2, 0, 0, 0 ].pack("n7") +
      segments.map(&:last).pack("n*") + [ 0 ].pack("n") + segments.map(&:first).pack("n*")
  end

  # A minimal sfnt: header, one `cmap` table record, and the cmap itself.
  #
  # `base` is where this font begins IN THE FILE. A table record's offset is
  # absolute from the start of the file, not from the start of its font — so
  # inside a TTC every font past the first needs its own base or the parser
  # seeks into the previous font's bytes. The first draft of this helper
  # hardcoded 0 and the TTC test caught it.
  def sfnt(subtables, base: 0)
    records = 4 + (8 * subtables.length)
    body = +""
    offsets = subtables.map { |st| (records + body.bytesize).tap { body << st } }
    cmap = [ 0, subtables.length ].pack("n2")
    offsets.each { |o| cmap += [ 3, 10, o ].pack("n2N") }
    cmap += body

    [ 0x00010000 ].pack("N") + [ 1, 0, 0, 0 ].pack("n4") +
      "cmap" + [ 0, base + 12 + 16, cmap.bytesize ].pack("N3") + cmap
  end

  def font_file(name, bytes)
    File.join(@dir, name).tap { |p| File.binwrite(p, bytes) }
  end

  def test_covers_reads_a_format_12_subtable
    path = font_file("f12.ttf", sfnt([ format12([ 0x1FA8E..0x1FA8F ]) ]))

    assert EmojiFont.covers?(0x1FA8E, path: path)
    assert EmojiFont.covers?(0x1FA8F, path: path)
    refute EmojiFont.covers?(0x1FA90, path: path), "a codepoint past the span reported present"
  end

  def test_covers_reads_a_format_4_subtable
    path = font_file("f4.ttf", sfnt([ format4([ [ 0x2600, 0x2610 ], [ 0xFFFF, 0xFFFF ] ]) ]))

    assert EmojiFont.covers?(0x2605, path: path)
    refute EmojiFont.covers?(0x2611, path: path)
  end

  # Apple Color Emoji is a TTC holding several fonts. Reading only the first
  # would under-report coverage and send someone hunting a replacement emoji for
  # one that is present.
  def test_covers_reads_every_font_in_a_ttc_container
    header = "ttcf" + [ 0x00020000 ].pack("N") + [ 2 ].pack("N")
    first = header.bytesize + 8 # the two uint32 font offsets that follow
    a = sfnt([ format12([ 0x1F400..0x1F410 ]) ], base: first)
    b = sfnt([ format12([ 0x1FA8E..0x1FA8E ]) ], base: first + a.bytesize)
    bytes = header + [ first, first + a.bytesize ].pack("N2") + a + b

    path = font_file("pair.ttc", bytes)

    assert EmojiFont.covers?(0x1F400, path: path), "the FIRST font in the collection was not read"
    assert EmojiFont.covers?(0x1FA8E, path: path), "the SECOND font in the collection was not read"
  end

  # A span wider than 0x20000 is a misparse. Kept, it makes covers? answer true
  # for everything — the worst possible failure here, because it certifies a
  # tofu box as present and the operator only finds out by looking at the menu.
  def test_an_absurdly_wide_span_is_dropped_rather_than_believed
    path = font_file("wide.ttf", sfnt([ format12([ 0x0..0x10FFFF ]) ]))

    refute EmojiFont.covers?(0x1FA8E, path: path)
  end

  def test_a_missing_font_reports_nothing_present_rather_than_raising
    refute EmojiFont.covers?(0x1FA8E, path: File.join(@dir, "absent.ttc"))
  end

  def test_suspect_codepoints_ignores_ascii_zwj_and_variation_selectors
    # 🧑‍🏭 is U+1F9D1 ZWJ U+1F3ED — two glyphs to check, not three.
    assert_equal [ 0x1F9D1, 0x1F3ED ], EmojiFont.suspect_codepoints("🧑‍🏭 welding")
    assert_empty EmojiFont.suspect_codepoints("main street")
  end

  # ---------------------------------------------------------------------------
  # Runtime — the architecture check that a slow browser needs
  # ---------------------------------------------------------------------------

  # Compared against the HOST rather than hardcoded to arm64, so the check stays
  # correct on an Intel Mac where x86_64 IS native.
  def test_chrome_is_translated_only_when_its_arch_differs_from_the_host
    Runtime.stub(:host_arch, "arm64") do
      Runtime.stub(:chrome_arch, "x86_64") { assert Runtime.chrome_translated? }
      Runtime.stub(:chrome_arch, "arm64") { refute Runtime.chrome_translated? }
      Runtime.stub(:chrome_arch, nil) do
        refute Runtime.chrome_translated?, "a Chrome that is not running is not translated"
      end
    end
    Runtime.stub(:host_arch, "x86_64") do
      Runtime.stub(:chrome_arch, "x86_64") do
        refute Runtime.chrome_translated?, "x86_64 is NATIVE on an Intel Mac"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Dock — the percent-encoding that cost a run
  # ---------------------------------------------------------------------------

  # The Dock stores its URLs percent-encoded. Matching on the RAW string is why a
  # first attempt at repointing the tile found zero Chrome tiles in a Dock that
  # plainly had one.
  def test_dock_urls_round_trip_through_percent_encoding
    path = "/Users/alex/Applications/Chrome (Ordered Profiles).app"
    encoded = Dock.encode(path)

    assert_equal "file:///Users/alex/Applications/Chrome%20%28Ordered%20Profiles%29.app/", encoded
    assert_equal "#{path}/", Dock.decode(encoded)
    refute_includes encoded, " ", "an unencoded space would not match what the Dock stores"
  end

  def test_dock_recognises_both_the_stock_app_and_the_wrapper
    assert Dock.chrome_tile?("#{CHROME_APP}/", nil)
    assert Dock.chrome_tile?("#{WRAPPER_APP}/", nil)
    assert Dock.chrome_tile?("/somewhere/else.app", Dock::BUNDLE_ID)
    refute Dock.chrome_tile?("/Applications/Safari.app/", "com.apple.Safari")
  end
end

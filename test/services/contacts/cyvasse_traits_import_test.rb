require "test_helper"

# [unit] Contacts::CyvasseTraitsImport (task contact-traits-from-cyvasse): the
# CSV from script/contacts/cyvasse_traits.rb lands on the matching contact as
# traits["cyvasse"], and nowhere else.
module Contacts
  class CyvasseTraitsImportTest < ActiveSupport::TestCase
    HEADER = CyvasseTraitsImport::HEADERS.join(",")
    SYNCED = "2026-09-30T12:00:00Z".freeze

    setup do
      @vey = Contact.create!(email: "vey@example.com", tags: %w[cyvasse-legacy],
                             traits: { "turf" => { "picks" => 4 } })
      @bob = Contact.create!(email: "bob@example.com", tags: %w[cyvasse-legacy])
    end

    def csv(*rows) = StringIO.new(([ HEADER ] + rows).join("\n") + "\n")

    def row(email, username: "veyjin", games: 27, finished: 25, wins: 20, losses: 7, rank: 12, synced: SYNCED)
      [ email, username, games, finished, wins, losses, "2014-03-02", "2026-09-01", rank, synced ].join(",")
    end

    test "a row lands on the contact its email names, case-insensitively, typed" do
      summary = CyvasseTraitsImport.new(csv(row("Vey@Example.COM"))).run

      assert_equal({ "username" => "veyjin", "games" => 27, "finished_games" => 25, "wins" => 20, "losses" => 7,
                     "joined_on" => "2014-03-02", "last_active_on" => "2026-09-01", "all_time_rank" => 12,
                     "synced_at" => SYNCED }, @vey.reload.cyvasse)
      assert_equal Contact::CYVASSE_TRAITS.sort, @vey.cyvasse.keys.sort, "the documented schema, exactly"
      assert_equal [ 1, 1, 1, 0 ], [ summary.rows, summary.matched, summary.updated, summary.unknown ]
      assert_equal({}, @bob.reload.cyvasse)
    end

    test "leaves other sources' traits and every other column alone" do
      @vey.update!(first_name: "Vey", subscribed: false)
      CyvasseTraitsImport.new(csv(row("vey@example.com"))).run
      @vey.reload

      assert_equal({ "picks" => 4 }, @vey.traits["turf"])
      assert_equal [ "Vey", false, %w[cyvasse-legacy] ], [ @vey.first_name, @vey.subscribed, @vey.tags ]
    end

    test "is idempotent: the same CSV twice writes nothing the second time" do
      CyvasseTraitsImport.new(csv(row("vey@example.com"), row("bob@example.com", username: "bob"))).run
      stamp = @vey.reload.updated_at

      again = CyvasseTraitsImport.new(csv(row("vey@example.com"), row("bob@example.com", username: "bob")),
                                      now: 1.hour.from_now).run
      assert_equal [ 2, 0, 2 ], [ again.matched, again.updated, again.unchanged ]
      assert_equal stamp, @vey.reload.updated_at
    end

    test "a newer sync replaces the traits; an older one is skipped as stale" do
      CyvasseTraitsImport.new(csv(row("vey@example.com"))).run
      newer = CyvasseTraitsImport.new(csv(row("vey@example.com", games: 28, synced: "2026-10-01T00:00:00Z"))).run
      assert_equal 1, newer.updated
      assert_equal 28, @vey.reload.cyvasse_games

      older = CyvasseTraitsImport.new(csv(row("vey@example.com", games: 1, synced: "2026-09-01T00:00:00Z"))).run
      assert_equal [ 1, 0 ], [ older.stale, older.updated ]
      assert_equal 28, @vey.reload.cyvasse_games
    end

    test "ignores unknown emails and never creates a contact" do
      assert_no_difference -> { Contact.count } do
        summary = CyvasseTraitsImport.new(csv(row("stranger@example.com"), row("vey@example.com"))).run
        assert_equal [ 1, 1 ], [ summary.unknown, summary.matched ]
      end
    end

    test "unusable rows are counted, not stored; a blank rank is nil" do
      bad = [ "no-at-sign,veyjin,1,1,1,1,2014-03-02,2026-09-01,1,#{SYNCED}",
              "vey@example.com,veyjin,many,1,1,1,2014-03-02,2026-09-01,1,#{SYNCED}",
              "vey@example.com,veyjin,1,1,1,1,not-a-date,2026-09-01,1,#{SYNCED}",
              "vey@example.com,,1,1,1,1,2014-03-02,2026-09-01,1,#{SYNCED}" ]
      summary = CyvasseTraitsImport.new(csv(*bad, row("bob@example.com", username: "bob", rank: nil))).run

      assert_equal [ 5, 4, 1 ], [ summary.rows, summary.invalid, summary.updated ]
      assert_equal({}, @vey.reload.cyvasse)
      assert_nil @bob.reload.cyvasse["all_time_rank"]
    end

    test "two accounts sharing an email once lowercased: the one with more games wins" do
      summary = CyvasseTraitsImport.new(csv(row("VEY@example.com", username: "old", games: 3),
                                            row("vey@example.com", username: "veyjin", games: 27),
                                            row("Vey@example.com", username: "alt", games: 5))).run
      assert_equal 2, summary.duplicates
      assert_equal "veyjin", @vey.reload.cyvasse["username"]
    end

    test "the summary is counts only, never a player's row" do
      text = CyvasseTraitsImport.new(csv(row("vey@example.com"))).run.to_s
      assert_match(/1 rows .* 1 matched a contact/, text)
      assert_no_match(/vey|veyjin/i, text)
    end
  end
end

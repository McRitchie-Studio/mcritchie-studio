require "test_helper"

# Bindings below are copied in shape from real SPARQL JSON answers
# (query.wikidata.org, 2026-09-29): Destiny's Child Q153056, Jay-Z Q62766.
class Artists::Wikidata::ParserTest < ActiveSupport::TestCase
  E = "http://www.wikidata.org/entity/".freeze

  def uri(qid) = { "type" => "uri", "value" => "#{E}#{qid}" }
  def lit(value, lang: nil) = { "type" => "literal", "value" => value }.merge(lang ? { "xml:lang" => lang } : {})
  def bool(value) = { "datatype" => "http://www.w3.org/2001/XMLSchema#boolean", "type" => "literal", "value" => value.to_s }
  def date(year) = { "datatype" => "http://www.w3.org/2001/XMLSchema#dateTime", "type" => "literal", "value" => "#{year}-01-01T00:00:00Z" }

  test "maps core rows to one artist per item, preferring the English label and the stable id" do
    core = [
      { "x" => uri("Q62766"), "mul" => lit("Jay-Z", lang: "mul"), "human" => bool(true), "group" => bool(false),
        "mb" => lit("f82bcf78-5b69-4622-a5ef-73800768d9ac"), "discogs" => lit("447899"), "spotify" => lit("3nFkdlSjzX9mRTtwJOzDYB") },
      { "x" => uri("Q62766"), "mul" => lit("Jay-Z", lang: "mul"), "human" => bool(true), "group" => bool(false),
        "mb" => lit("f82bcf78-5b69-4622-a5ef-73800768d9ac"), "discogs" => lit("21742"), "spotify" => lit("3nFkdlSjzX9mRTtwJOzDYB") },
      { "x" => uri("Q153056"), "en" => lit("Destiny's Child", lang: "en"), "mul" => lit("Destinys Child", lang: "mul"),
        "human" => bool(false), "group" => bool(true), "discogs" => lit("22008") },
      { "x" => uri("Q999"), "en" => lit("An Album", lang: "en"), "human" => bool(false), "group" => bool(false) }
    ]
    aliases = [
      { "x" => uri("Q62766"), "alias" => lit("Hova", lang: "mul") },
      { "x" => uri("Q62766"), "alias" => lit("Shawn Corey Carter", lang: "mul") },
      { "x" => uri("Q62766"), "alias" => lit("Shawn Corey Carter", lang: "en") },
      { "x" => uri("Q62766"), "alias" => lit("jay-z", lang: "en") },
      { "x" => uri("Q153056"), "alias" => lit("Girl's Tyme", lang: "en") }
    ]

    artists = Artists::Wikidata::Parser.artists(core, aliases).index_by { |a| a["wikidata_id"] }

    assert_equal %w[Q153056 Q62766], artists.keys.sort, "an item neither human nor musical group is dropped"

    jay = artists["Q62766"]
    assert_equal "Jay-Z", jay["name"], "falls back to the multilingual label"
    assert_equal "person", jay["kind"]
    assert_equal "f82bcf78-5b69-4622-a5ef-73800768d9ac", jay["musicbrainz_id"]
    assert_equal "21742", jay["discogs_id"], "of several ids, the shortest then lowest wins, whatever the row order"
    assert_equal "3nFkdlSjzX9mRTtwJOzDYB", jay["spotify_id"]
    assert_equal [{ "name" => "Hova", "locale" => "mul" }, { "name" => "Shawn Corey Carter", "locale" => "en" }],
                 jay["aliases"], "English beats mul for the same alias; an alias equal to the name is dropped"

    dc = artists["Q153056"]
    assert_equal "Destiny's Child", dc["name"]
    assert_equal "group", dc["kind"]
    assert_nil dc["spotify_id"]
    assert_equal [{ "name" => "Girl's Tyme", "locale" => "en" }], dc["aliases"]
  end

  test "maps membership rows to stints, taking the better-dated direction per pair" do
    rows = [
      # Beyoncé: the group says 1990-; she says 1990-2005. Her side has more dates.
      { "member" => uri("Q36153"), "group" => uri("Q153056"), "via" => lit("part"), "start" => date(1990) },
      { "member" => uri("Q36153"), "group" => uri("Q153056"), "via" => lit("member_of"), "start" => date(1990), "end" => date(2005) },
      # Farrah Franklin: equal detail, the group's own statement wins.
      { "member" => uri("Q292623"), "group" => uri("Q153056"), "via" => lit("part"), "start" => date(2000), "end" => date(2001) },
      { "member" => uri("Q292623"), "group" => uri("Q153056"), "via" => lit("member_of"), "start" => date(1999), "end" => date(2000) },
      # Undated and duplicated rows collapse to one stint.
      { "member" => uri("Q30072039"), "group" => uri("Q15777045"), "via" => lit("part") },
      { "member" => uri("Q30072039"), "group" => uri("Q15777045"), "via" => lit("part") },
      # Two stints from the same direction both survive.
      { "member" => uri("Q1"), "group" => uri("Q2"), "via" => lit("part"), "start" => date(1980), "end" => date(1985) },
      { "member" => uri("Q1"), "group" => uri("Q2"), "via" => lit("part"), "start" => date(1990) },
      # Unknown value (a blank node) reads as no year.
      { "member" => uri("Q3"), "group" => uri("Q2"), "via" => lit("part"), "start" => { "type" => "bnode", "value" => "t1" } }
    ]

    stints = Artists::Wikidata::Parser.memberships(rows)

    assert_equal [
      { "member" => "Q1", "group" => "Q2", "start_year" => 1980, "end_year" => 1985 },
      { "member" => "Q1", "group" => "Q2", "start_year" => 1990, "end_year" => nil },
      { "member" => "Q3", "group" => "Q2", "start_year" => nil, "end_year" => nil },
      { "member" => "Q36153", "group" => "Q153056", "start_year" => 1990, "end_year" => 2005 },
      { "member" => "Q292623", "group" => "Q153056", "start_year" => 2000, "end_year" => 2001 },
      { "member" => "Q30072039", "group" => "Q15777045", "start_year" => nil, "end_year" => nil }
    ], stints, "sorted by numeric member id, group id, then start year"
  end

  test "pairs a statement's several start and end qualifiers instead of crossing them" do
    # Maroon 5 / Jesse Carmichael (Q459375): one statement, starts 1994 and
    # 2014, end 2012. SPARQL returns the cross product, including 2014-2012.
    st = { "type" => "uri", "value" => "http://www.wikidata.org/entity/statement/Q182223-abc" }
    rows = [[1994, 2012], [2014, 2012]].map do |start, finish|
      { "member" => uri("Q459375"), "group" => uri("Q182223"), "via" => lit("part"), "st" => st,
        "start" => date(start), "end" => date(finish) }
    end

    assert_equal [
      { "member" => "Q459375", "group" => "Q182223", "start_year" => 1994, "end_year" => 2012 },
      { "member" => "Q459375", "group" => "Q182223", "start_year" => 2014, "end_year" => nil }
    ], Artists::Wikidata::Parser.memberships(rows)
  end

  test "qid and year read the raw values" do
    assert_equal "Q62766", Artists::Wikidata::Parser.qid("#{E}Q62766")
    assert_nil Artists::Wikidata::Parser.qid("_:t1")
    assert_equal 2008, Artists::Wikidata::Parser.year("2008-01-01T00:00:00Z")
    assert_nil Artists::Wikidata::Parser.year("t12")
    assert_nil Artists::Wikidata::Parser.year(nil)
  end
end

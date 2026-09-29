require "test_helper"

class Artists::Wikidata::FetcherTest < ActiveSupport::TestCase
  E = "http://www.wikidata.org/entity/".freeze

  # Answers each query by its shape, the way the endpoint would.
  class FakeClient
    def initialize(answers) = @answers = answers

    def select(query)
      key = @answers.keys.find { |pattern| query.include?(pattern) }
      rows = @answers.fetch(key)
      rows.respond_to?(:call) ? rows.call(query) : rows
    end
  end

  def uri(qid) = { "value" => "#{E}#{qid}" }
  def lit(value) = { "value" => value }

  test "seeds rappers and groups, adds their members, and drops links to anything else" do
    client = FakeClient.new(
      "wdt:P106" => [{ "x" => uri("Q10") }],                      # a rapper
      "wdt:P136" => [{ "x" => uri("Q20") }],                      # a hip-hop group
      "p:P527" => [
        { "member" => uri("Q10"), "group" => uri("Q20"), "via" => lit("part") },
        { "member" => uri("Q30"), "group" => uri("Q20"), "via" => lit("part"), "start" => lit("2001-01-01T00:00:00Z") },
        { "member" => uri("Q40"), "group" => uri("Q20"), "via" => lit("part") } # an album, not an artist
      ],
      "skos:altLabel" => [],
      "rdfs:label" => lambda { |query|
        { "Q10" => true, "Q20" => false, "Q30" => true }.filter_map do |qid, human|
          next unless query.include?("wd:#{qid}")

          { "x" => uri(qid), "en" => lit("Name #{qid}"), "human" => lit(human.to_s), "group" => lit((!human).to_s) }
        end
      }
    )

    snapshot = Artists::Wikidata::Fetcher.new(client: client).call

    assert_equal "CC0-1.0", snapshot["license"]
    assert_equal [%w[Q10 person rapper], %w[Q20 group group], %w[Q30 person member]],
                 snapshot["artists"].map { |a| a.values_at("wikidata_id", "kind", "seed") }
    assert_equal [%w[Q10 Q20], %w[Q30 Q20]], snapshot["memberships"].map { |m| m.values_at("member", "group") }
  end

  test "writes one artist per line and reads back as the same snapshot" do
    snapshot = { "source" => "Wikidata", "artists" => [{ "wikidata_id" => "Q1" }, { "wikidata_id" => "Q2" }],
                 "memberships" => [{ "member" => "Q1", "group" => "Q2" }] }
    Tempfile.create(["artists", ".json"]) do |file|
      Artists::Wikidata::Fetcher.write(snapshot, file.path)
      text = File.read(file.path)
      assert_equal snapshot, JSON.parse(text)
      assert_includes text, "\n    {\"wikidata_id\":\"Q2\"}\n"
    end
  end
end

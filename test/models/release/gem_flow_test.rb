require "test_helper"

# Which gem flow a release runs, and the decisions the final flow adds.
# docs/agents/system/gem-release-flow.md
class Release::GemFlowTest < ActiveSupport::TestCase
  F = Release::GemFlow

  test "the final flow is the default, and only an exact candidate restores the old one" do
    assert_equal :final, F.mode({})
    assert_equal :final, F.mode("RELEASE_GEM_FLOW" => "")
    assert_equal :final, F.mode("RELEASE_GEM_FLOW" => "candiate"), "a typo never selects the slower flow"
    assert_equal :candidate, F.mode("RELEASE_GEM_FLOW" => " Candidate ")
    assert F.final?({})
    assert_not F.final?("RELEASE_GEM_FLOW" => "candidate")
  end

  test "prepare publishes the final when RubyGems does not list it" do
    action = F.prepare_action(final: "0.117.0", live: [{ "number" => "0.116.1" }, { "number" => "0.117.0.rc1" }])
    assert action.publish?
    assert_equal "0.117.0", action.version
  end

  test "prepare reuses a final already live (the re-run at the same tip)" do
    action = F.prepare_action(final: "0.117.0", live: %w[0.116.1 0.117.0])
    assert action.final_live?
    assert_not action.publish?
  end

  # --- the unshipped-final guard ---

  def findings(locked, wanted: {}, main: "0.116.1")
    F.unshipped_final_findings(locks: { "turf-monster" => { "studio-engine" => locked } },
                               shipped: { "studio-engine" => main }, wanted: wanted)
  end

  test "a consumer on a final past the gem's main, which this release does not carry, is a finding" do
    found = findings("0.117.0")
    assert_equal 1, found.size
    assert_includes found.first, "turf-monster locks studio-engine 0.117.0, a version past studio-engine's main (0.116.1)"
    assert_includes found.first, "this release does not carry"
  end

  test "the release that carries the gem at that version may lock it" do
    assert_empty findings("0.117.0", wanted: { "studio-engine" => "0.117.0" })
  end

  test "a burned final, with the release now carrying the next patch, is a finding" do
    found = findings("0.117.0", wanted: { "studio-engine" => "0.117.1" })
    assert_includes found.first, "it carries 0.117.1"
  end

  test "a lock on the shipped version, or older, is no finding" do
    assert_empty findings("0.116.1")
    assert_empty findings("0.115.0")
  end

  test "an unreadable main, an absent lock or an unparsable version is no finding" do
    assert_empty findings("0.117.0", main: "")
    assert_empty findings(nil)
    assert_empty findings("not-a-version")
  end

  test "an uncarried candidate above main is a finding too; a carried one is not" do
    assert_equal 1, findings("0.117.0.rc1").size
    assert_empty findings("0.117.0.rc1", wanted: { "studio-engine" => "0.117.0.rc1" })
  end

  # --- burned versions ---

  test "a burned version below the gem's main is a finding: the above-main read alone passes it" do
    assert_empty findings("0.117.0", main: "0.117.1"), "the gap: 0.117.0 sits below main once 0.117.1 ships"

    found = F.unshipped_final_findings(locks: { "turf-monster" => { "studio-engine" => "0.117.0" } },
                                       shipped: { "studio-engine" => "0.117.1" }, wanted: {},
                                       burned: { "studio-engine" => %w[0.117.0] })
    assert_equal 1, found.size
    assert_includes found.first, "turf-monster locks studio-engine 0.117.0, a BURNED version"
  end

  test "a burned version is refused even when main is unreadable or the release names it" do
    burned = { "studio-engine" => %w[0.117.0] }
    locks  = { "turf-monster" => { "studio-engine" => "0.117.0" } }
    assert_equal 1, F.unshipped_final_findings(locks: locks, shipped: {}, wanted: {}, burned: burned).size
    assert_equal 1, F.unshipped_final_findings(locks: locks, shipped: { "studio-engine" => "0.116.1" },
                                               wanted: { "studio-engine" => "0.117.0" }, burned: burned).size
  end

  test "a lock on a version not in the burned set is judged as before" do
    assert_empty F.unshipped_final_findings(locks: { "turf-monster" => { "studio-engine" => "0.117.1" } },
                                            shipped: { "studio-engine" => "0.117.1" }, wanted: {},
                                            burned: { "studio-engine" => %w[0.117.0] })
  end

  test "a final above main and below the version this release carries is newly burned" do
    assert_equal %w[0.117.0 0.117.1],
                 F.newly_burned(published: %W[v0.116.0\n v0.116.1 v0.117.1 v0.117.0], shipped: "0.116.1",
                                carried: "0.117.2")
  end

  test "the shipped version, the carried one and anything past it are never burned" do
    assert_empty F.newly_burned(published: %w[v0.116.1 v0.117.0], shipped: "0.116.1", carried: "0.117.0"),
                 "the re-run that reuses 0.117.0 burns nothing"
    assert_empty F.newly_burned(published: %w[v0.118.0], shipped: "0.116.1", carried: "0.117.0")
  end

  test "an unreadable main or carried version records nothing, and junk tags are ignored" do
    assert_empty F.newly_burned(published: %w[v0.117.0], shipped: "", carried: "0.117.1")
    assert_empty F.newly_burned(published: %w[v0.117.0], shipped: "0.116.1", carried: "")
    assert_empty F.newly_burned(published: %w[vnext], shipped: "0.116.1", carried: "0.117.1")
  end

  test "burned tags round-trip, and the prefix never reads as a v* tag" do
    assert_equal "burned-v0.117.0", F.burned_tag("0.117.0")
    assert_equal %w[0.117.0 0.118.2], F.burned_versions("burned-v0.117.0\nburned-v0.118.2\nv0.119.0\nburned-v\n")
    assert_not F.burned_tag("0.117.0").start_with?("v")
  end

  # --- the RubyGems listing, fail closed ---

  test "a 200 listing is the live versions, and a 404 is a gem never published" do
    assert_equal [{ "number" => "0.117.0" }], F.listing("200", %([{"number":"0.117.0"}]))
    assert_equal [], F.listing("404", "This rubygem could not be found.")
  end

  test "any other answer is unreadable, never empty" do
    ["", "000", "500", "503", "429"].each do |code|
      error = assert_raises(F::ListingUnreadable) { F.listing(code, "") }
      assert_match(/HTTP/, error.message)
    end
    assert_raises(F::ListingUnreadable) { F.listing("200", "<html>maintenance</html>") }
    assert_raises(F::ListingUnreadable) { F.listing("200", %({"error":"rate limited"})) }
  end
end

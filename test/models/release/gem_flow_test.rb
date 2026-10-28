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
end

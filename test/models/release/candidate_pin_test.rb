require "test_helper"

# The consumer Gemfile line while a candidate is under QA, and after the ship.
class Release::CandidatePinTest < ActiveSupport::TestCase
  R = Release::GemfileRepin
  S = Release::ShipSequence

  PLAIN = %(source "https://rubygems.org"\ngem "rails"\ngem "studio-engine", "~> 0.95" # the floor\ngem "pg"\n)

  test "pinning adds the exact candidate after the line's own requirement" do
    assert_includes R.pin_candidate(PLAIN, "studio-engine", "0.96.0.rc1"),
                    %(gem "studio-engine", "~> 0.95", "0.96.0.rc1" # the floor\n)
    assert_equal "0.96.0.rc1", R.candidate_pin(R.pin_candidate(PLAIN, "studio-engine", "0.96.0.rc1"), "studio-engine")
  end

  test "dropping the candidate gives back the original text byte for byte" do
    assert_equal PLAIN, R.drop_candidate(R.pin_candidate(PLAIN, "studio-engine", "0.96.0.rc1"), "studio-engine")
    assert_equal PLAIN, R.drop_candidate(PLAIN, "studio-engine")
    assert_nil R.candidate_pin(PLAIN, "studio-engine")
  end

  test "a second candidate replaces the first" do
    twice = R.pin_candidate(R.pin_candidate(PLAIN, "studio-engine", "0.96.0.rc1"), "studio-engine", "0.96.0.rc2")
    assert_includes twice, %(gem "studio-engine", "~> 0.95", "0.96.0.rc2" # the floor\n)
    assert_not_includes twice, "rc1"
  end

  test "options stay after the requirements, and other quoting survives" do
    text = %(  gem 'solana-studio', '~> 0.12', '>= 0.12.3', require: false\n)
    pinned = R.pin_candidate(text, "solana-studio", "0.13.0.rc1")
    assert_equal %(  gem 'solana-studio', '~> 0.12', '>= 0.12.3', "0.13.0.rc1", require: false\n), pinned
    assert_equal text, R.drop_candidate(pinned, "solana-studio")
  end

  test "a bare line takes the candidate as its only requirement" do
    assert_equal %(gem "x", "1.2.3.rc4"\n), R.pin_candidate(%(gem "x"\n), "x", "1.2.3.rc4")
  end

  test "only the named gem's line moves" do
    text = %(gem "studio-engine-extras", "~> 1.0"\ngem "studio-engine", "~> 0.95"\n)
    assert_equal %(gem "studio-engine-extras", "~> 1.0"\ngem "studio-engine", "~> 0.95", "0.96.0.rc1"\n),
                 R.pin_candidate(text, "studio-engine", "0.96.0.rc1")
  end

  # --- locked_gemfile: what prepare and ship each write ---

  test "the ship's Gemfile is the prepare's minus the candidate requirement" do
    prepared = S.locked_gemfile(PLAIN, "studio-engine", "0.96.0.rc1")
    assert_includes prepared, %("~> 0.95", "0.96.0.rc1")
    assert_equal PLAIN, S.locked_gemfile(prepared, "studio-engine", "0.96.0")
  end

  test "a final that escapes the pin rewrites it, under the candidate and after" do
    prepared = S.locked_gemfile(PLAIN, "studio-engine", "1.0.0.rc1")
    assert_includes prepared, %(gem "studio-engine", "~> 1.0", "1.0.0.rc1" # the floor\n)
    assert_includes S.locked_gemfile(prepared, "studio-engine", "1.0.0"), %(gem "studio-engine", "~> 1.0" # the floor\n)
  end

  test "a source ref becomes a version pin plus the candidate" do
    text = %(gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"\n)
    assert_equal %(gem "studio-engine", "~> 0.96", "0.96.0.rc1"\n), S.locked_gemfile(text, "studio-engine", "0.96.0.rc1")
  end

  test "a gem the Gemfile never declares leaves it untouched" do
    assert_equal PLAIN, S.locked_gemfile(PLAIN, "solana-studio", "0.13.0.rc1")
  end

  # --- gems_to_relock ---

  LOCK = "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (%s)\n\nDEPENDENCIES\n  studio-engine (~> 0.95)\n"

  test "a candidate pin, a source ref and a prerelease lock each need the relock" do
    pinned = R.pin_candidate(PLAIN, "studio-engine", "0.96.0.rc1")
    assert_equal ["studio-engine"], S.gems_to_relock(%w[studio-engine solana-studio], pinned, format(LOCK, "0.96.0.rc1"))
    assert_equal ["studio-engine"], S.gems_to_relock(["studio-engine"], %(gem "studio-engine", path: "../x"\n))
    # The pin is gone but the lock kept the candidate: Bundler accepts that lock as is.
    assert_equal ["studio-engine"], S.gems_to_relock(["studio-engine"], PLAIN, format(LOCK, "0.96.0.rc1"))
  end

  test "a plain pin on a released version needs nothing" do
    assert_equal [], S.gems_to_relock(["studio-engine"], PLAIN, format(LOCK, "0.96.0"))
    assert_equal [], S.gems_to_relock(["studio-engine"], PLAIN)
  end
end

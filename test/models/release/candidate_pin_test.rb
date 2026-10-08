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

  # --- locked_gemfile: what prepare and ship each COMMIT ---

  # Every committed line must admit the version it is committed for: a line that
  # does not is a Gemfile no Bundler can resolve.
  def admits?(text, version)
    Gem::Requirement.new(*R.version_requirements(text, "studio-engine")).satisfied_by?(Gem::Version.new(version))
  end

  test "an in-range candidate changes no Gemfile line at prepare or at ship" do
    prepared = S.locked_gemfile(PLAIN, "studio-engine", "0.96.0.rc1")
    assert_equal PLAIN, prepared
    assert admits?(prepared, "0.96.0.rc1")
    assert_equal PLAIN, S.locked_gemfile(prepared, "studio-engine", "0.96.0")
  end

  test "the resolving Gemfile names the candidate exactly and comes straight back off" do
    resolving = S.resolving_gemfile(PLAIN, "studio-engine", "0.96.0.rc1")
    assert_includes resolving, %(gem "studio-engine", "~> 0.95", "0.96.0.rc1" # the floor\n)
    assert admits?(resolving, "0.96.0.rc1")
    assert_equal PLAIN, R.drop_candidate(resolving, "studio-engine")
    assert_equal PLAIN, S.resolving_gemfile(PLAIN, "studio-engine", "0.96.0"), "a final resolves from the committed text"
  end

  # The pin the final would get, "~> 1.0", EXCLUDES 1.0.0.rc1: a prerelease sorts
  # below its final. The committed line keeps that range and opens its floor.
  test "a candidate whose final escapes the pin gets a line that admits both" do
    assert_not Gem::Requirement.new("~> 1.0").satisfied_by?(Gem::Version.new("1.0.0.rc1")), "the trap this guards"

    prepared = S.locked_gemfile(PLAIN, "studio-engine", "1.0.0.rc1")
    assert_includes prepared, %(gem "studio-engine", ">= 1.0.0.rc1", "< 2" # the floor\n)
    assert admits?(prepared, "1.0.0.rc1")
    assert admits?(prepared, "1.0.0")
    assert_not admits?(prepared, "2.0.0")
    assert admits?(S.resolving_gemfile(prepared, "studio-engine", "1.0.0.rc1"), "1.0.0.rc1")

    shipped = S.locked_gemfile(prepared, "studio-engine", "1.0.0")
    assert_includes shipped, %(gem "studio-engine", "~> 1.0" # the floor\n)
    assert_equal shipped, S.locked_gemfile(PLAIN, "studio-engine", "1.0.0"), "the ship's line is the final's own"
  end

  test "a minor that escapes a three-segment pin gets the same treatment" do
    text = %(gem "studio-engine", "~> 0.95.0", require: false\n)
    prepared = S.locked_gemfile(text, "studio-engine", "0.96.0.rc1")
    assert_equal %(gem "studio-engine", ">= 0.96.0.rc1", "< 1", require: false\n), prepared
    assert admits?(prepared, "0.96.0.rc1")
    assert_equal %(gem "studio-engine", "~> 0.96", require: false\n), S.locked_gemfile(prepared, "studio-engine", "0.96.0")
  end

  test "a source ref becomes a version line that admits the candidate, then the final's pin" do
    text = %(gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"\n)
    prepared = S.locked_gemfile(text, "studio-engine", "0.97.0.rc1")
    assert_equal %(gem "studio-engine", ">= 0.97.0.rc1", "< 1"\n), prepared
    assert admits?(prepared, "0.97.0.rc1")
    assert_equal %(gem "studio-engine", "~> 0.97"\n), S.locked_gemfile(prepared, "studio-engine", "0.97.0")
    assert_equal S.locked_gemfile(text, "studio-engine", "0.97.0"), S.locked_gemfile(prepared, "studio-engine", "0.97.0")
  end

  # A QA bounce: the line already carries rc1's floor and the next candidate is rc2.
  test "a second candidate keeps a line that admits it" do
    prepared = S.locked_gemfile(PLAIN, "studio-engine", "1.0.0.rc1")
    again = S.locked_gemfile(prepared, "studio-engine", "1.0.0.rc2")
    assert_equal prepared, again
    assert admits?(again, "1.0.0.rc2")
  end

  test "a gem the Gemfile never declares leaves it untouched" do
    assert_equal PLAIN, S.locked_gemfile(PLAIN, "solana-studio", "0.13.0.rc1")
  end

  # --- gems_to_relock ---

  LOCK = "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (%s)\n\nDEPENDENCIES\n  studio-engine (~> 0.95)\n"

  test "a prerelease lock, a candidate floor and a source ref each need the relock" do
    # The usual case: the Gemfile is untouched and only the lock names the candidate.
    assert_equal ["studio-engine"], S.gems_to_relock(%w[studio-engine solana-studio], PLAIN, format(LOCK, "0.96.0.rc1"))
    floored = S.locked_gemfile(PLAIN, "studio-engine", "1.0.0.rc1")
    assert_equal ["studio-engine"], S.gems_to_relock(["studio-engine"], floored, format(LOCK, "0.95.2"))
    assert_equal ["studio-engine"], S.gems_to_relock(["studio-engine"], %(gem "studio-engine", path: "../x"\n))
  end

  test "a plain pin on a released version needs nothing" do
    assert_equal [], S.gems_to_relock(["studio-engine"], PLAIN, format(LOCK, "0.96.0"))
    assert_equal [], S.gems_to_relock(["studio-engine"], PLAIN)
  end
end

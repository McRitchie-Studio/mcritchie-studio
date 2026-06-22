require "test_helper"

class Release::GemfileRepinTest < ActiveSupport::TestCase
  # --- pessimistic_constraint ---

  test "pessimistic_constraint takes major.minor" do
    assert_equal "~> 0.9", Release::GemfileRepin.pessimistic_constraint("0.9.3")
    assert_equal "~> 1.2", Release::GemfileRepin.pessimistic_constraint("1.2.0")
    assert_equal "~> 0.8", Release::GemfileRepin.pessimistic_constraint("0.8")
    assert_equal "~> 12.4", Release::GemfileRepin.pessimistic_constraint("12.4.99")
  end

  test "pessimistic_constraint falls back to major-only for a bare major" do
    assert_equal "~> 1", Release::GemfileRepin.pessimistic_constraint("1")
  end

  # --- references_branch? ---

  test "references_branch? is true for a github source line" do
    text = %(gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/standard-link-model"\n)
    assert Release::GemfileRepin.references_branch?(text, "studio-engine")
  end

  test "references_branch? is true for git:, path:, and bare branch: forms" do
    assert Release::GemfileRepin.references_branch?(%(gem "x", git: "https://example/x.git"\n), "x")
    assert Release::GemfileRepin.references_branch?(%(gem "x", path: "../x"\n), "x")
    assert Release::GemfileRepin.references_branch?(%(gem "x", github: "o/x", branch: "main"\n), "x")
  end

  test "references_branch? is false for a plain pessimistic pin" do
    assert_not Release::GemfileRepin.references_branch?(%(gem "studio-engine", "~> 0.8"\n), "studio-engine")
  end

  test "references_branch? is false for an exact version pin" do
    assert_not Release::GemfileRepin.references_branch?(%(gem "studio-engine", "0.8.0"\n), "studio-engine")
  end

  test "references_branch? is false when the gem is absent" do
    assert_not Release::GemfileRepin.references_branch?(%(gem "rails"\n), "studio-engine")
  end

  test "references_branch? does not false-match github: as git:" do
    # github: must be detected as a source ref, not skipped because git: didn't match.
    assert Release::GemfileRepin.references_branch?(%(gem "x", github: "o/x"\n), "x")
  end

  # --- rewrite: github -> ~> ---

  test "rewrite replaces a github/branch line with a pessimistic pin" do
    text = %(gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/standard-link-model"\n)
    out = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
    assert_equal %(gem "studio-engine", "~> 0.9"\n), out
  end

  test "rewrite handles the real solana-studio-style git line" do
    text = %(gem "solana-studio", git: "https://github.com/amcritchie/solana-studio", branch: "main"\n)
    out = Release::GemfileRepin.rewrite(text, "solana-studio", "0.4.7")
    assert_equal %(gem "solana-studio", "~> 0.4"\n), out
  end

  # --- rewrite: idempotent ---

  test "rewrite is idempotent on an already-pessimistic pin" do
    text = %(gem "studio-engine", "~> 0.8"\n)
    assert_equal text, Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
  end

  test "rewrite leaves an exact version pin untouched" do
    text = %(gem "studio-engine", "0.8.0"\n)
    assert_equal text, Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
  end

  test "rewrite running twice equals running once" do
    text = %(gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"\n)
    once = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
    twice = Release::GemfileRepin.rewrite(once, "studio-engine", "0.9.3")
    assert_equal once, twice
  end

  # --- rewrite: formatting preserved ---

  test "rewrite preserves leading indentation" do
    text = %(  gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"\n)
    out = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
    assert_equal %(  gem "studio-engine", "~> 0.9"\n), out
  end

  test "rewrite preserves a trailing comment" do
    text = %(gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x" # repin after ship\n)
    out = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
    assert_equal %(gem "studio-engine", "~> 0.9" # repin after ship\n), out
  end

  test "rewrite only touches the targeted gem's line in a multi-line Gemfile" do
    text = <<~GEMFILE
      source "https://rubygems.org"

      gem "rails", "~> 7.2"
      gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"
      gem "solana-studio", "~> 0.4"
    GEMFILE

    out = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")

    expected = <<~GEMFILE
      source "https://rubygems.org"

      gem "rails", "~> 7.2"
      gem "studio-engine", "~> 0.9"
      gem "solana-studio", "~> 0.4"
    GEMFILE

    assert_equal expected, out
  end

  test "rewrite does not match a gem whose name is a prefix of the target" do
    text = %(gem "studio-engine-extras", github: "o/studio-engine-extras", branch: "x"\n)
    assert_equal text, Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
  end

  test "rewrite preserves a final line without a trailing newline" do
    text = %(gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x")
    out = Release::GemfileRepin.rewrite(text, "studio-engine", "0.9.3")
    assert_equal %(gem "studio-engine", "~> 0.9"), out
  end
end

# frozen_string_literal: true

# [unit] The hand-mint recipe in token-session.md must work when 1Password does
# not: it names an identity whose app id config/github_apps.yml records
# (test/lib/github_apps_config_test.rb proves the minter reads it), it never calls
# `op`, and it never exports or proves an empty token. The private key itself is
# never committed.

require "bundler/setup"
require "minitest/autorun"

class HandMintRecipeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  SOP = "docs/agents/modules/token-session.md"

  # The heading the SOP's hand-mint recipe lives under. Matched loosely on
  # purpose: the rule is "a section about minting when 1Password is down
  # exists", not "this exact wording exists".
  RECIPE_HEADING = /^##+ .*1Password.*(?:down|unreachable).*mint/i

  def read(rel) = File.read(File.join(ROOT, rel))

  # ── 4. THE RECIPE MUST NOT ROUTE BACK THROUGH 1PASSWORD ─────────────────────
  #
  # The whole point of the section is that it works when `op` does not. A
  # well-meaning "use the helper instead" edit restores the circularity while
  # leaving the section looking correct.
  def test_the_hand_mint_recipe_reaches_no_1password
    block = recipe_block

    assert_match(/GH_APP_IDENTITY=(?:agent|deployer)\b/, block,
      "the hand-mint recipe must name the identity whose app id " \
      "config/github_apps.yml records; that is the half that used to be unavailable.")
    assert_match(%r{gh-app-mint-token}, block,
      "the recipe must call the minter that takes its inputs from the environment.")
    refute_match(/\bop\s+(?:read|item|inject|signin|run)\b/, block,
      "the hand-mint recipe invokes `op`. It exists precisely for the case where " \
      "`op` cannot answer; routing it back through 1Password restores the circle.")
  end

  # ── 5. THE RECIPE KEEPS THE EMPTY-TOKEN GUARD ───────────────────────────────
  #
  # The same SOP documents that `gh` treats an empty GH_TOKEN as "unset" and
  # falls back to the keyring, where a PERSONAL account may be signed in — that
  # is how two merges once landed under Mr. McRitchie's own name. A recipe that
  # exports the result of a mint unconditionally walks straight into it.
  def test_the_recipe_checks_the_token_before_exporting_it
    block = recipe_block

    assert_match(/\[\s*-[zn]\s+"\$GH_TOKEN"\s*\]/, block,
      "the recipe exports GH_TOKEN without testing it for emptiness first; a " \
      "failed mint would hand `gh` an empty token and it would silently fall " \
      "back to the keyring identity.")
  end

  # A failed mint leaves GH_TOKEN unset, and `gh` then falls back to the KEYRING,
  # where the proof call still answers — certifying a mint that never happened.
  def test_the_recipes_proof_call_runs_only_when_the_mint_succeeded
    block   = recipe_block
    guarded = block[/^if\s+\[\s*-z\s+"\$GH_TOKEN"\s*\].*?^fi$/m]
    refute_nil guarded, "the recipe's empty-token guard is not a multi-line block."

    proof = block.lines.grep(/\bgh\s+api\b/).map(&:strip)
    refute_empty proof, "the recipe carries no proof call to place."
    proof.each do |line|
      assert_includes guarded, line,
        "the recipe runs `#{line}` OUTSIDE the empty-token guard; after a failed " \
        "mint `gh` falls back to the keyring and it answers anyway."
    end
  end

  # ── 6. THE SECRET HALF IS NEVER IN THE REPO ─────────────────────────────────
  #
  # The id is recorded BECAUSE it is not a credential. The line that makes that
  # true is this one, so it is the one worth enforcing mechanically.
  def test_no_private_key_material_is_recorded_anywhere_in_the_agent_docs
    offenders = Dir[File.join(ROOT, "docs/**/*.md")].select do |path|
      File.read(path).match?(/-----BEGIN (?:RSA |ENCRYPTED |OPENSSH )?PRIVATE KEY-----/)
    end

    assert_empty offenders.map { |p| p.sub("#{ROOT}/", "") },
      "private key material is committed. The app id is public metadata; the " \
      "`.pem` is the credential and belongs only in 1Password."
  end

  private

  def recipe_block
    sop = read(SOP)
    heading_index = sop.lines.index { |line| line.match?(RECIPE_HEADING) }
    refute_nil heading_index,
      "#{SOP} has no section documenting how to mint when 1Password is down. " \
      "Its lifecycle table routes the `1Password unreachable / quota spent` row " \
      "to the reader, so the reader needs somewhere to land."

    rest = sop.lines[heading_index..].join
    block = rest[/```bash\n(.*?)```/m, 1]
    refute_nil block, "the mint-by-hand section carries no runnable bash block."
    block
  end
end

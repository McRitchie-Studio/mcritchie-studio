# frozen_string_literal: true

# [unit] The two GitHub App ids must stay written down, and the hand-mint recipe
# that uses them must stay reachable WITHOUT 1Password. Sibling of
# test/lib/token_session_sop_claims_test.rb, which pins the same SOP's claims
# about who owns a credential failure.
#
# ---------------------------------------------------------------------------
# THE DEFECT (2026-08-30, measured — it cost a night's pushes).
#
# credential-inventory.md named the FIELDS each GitHub App item carries
# ("Fields: `app-id`, `client-id`") but never the app-id VALUES. So the number
# `bin/gh-app-mint-token` requires lived in exactly one place: 1Password. The
# documented fallback for "1Password is unreachable" is to mint from the `.pem`
# by hand — which needs that number. The fallback for the outage required the
# service that was out. Three finished tasks could not be pushed.
#
# WHY A TEST AND NOT JUST THE EDIT. The failure mode is DELETION, and it is
# silent: an app id looks like a credential to a careful reader, so the next
# person tidying this file has every reason to strip it, and nothing would fail.
# The outage would come back with the fix already in the git history.
# ---------------------------------------------------------------------------
#
# WHY PROPERTIES RATHER THAN PINNED NUMBERS. Only one assertion below names a
# literal, and it names a forbidden one (PEM markers). The ids are READ from the
# inventory and then required to agree with the SOP, so a legitimate rotation
# stays a one-line edit while a deletion or a drift between the two docs fails.

require "bundler/setup"
require "minitest/autorun"

class AppIdRecordedClaimsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  INVENTORY = "docs/agents/modules/credential-inventory.md"
  SOP       = "docs/agents/modules/token-session.md"

  ITEMS = %w[github.mcritchie-agent github.mcritchie-deployer].freeze

  # The heading the SOP's hand-mint recipe lives under. Matched loosely on
  # purpose: the rule is "a section about minting when 1Password is down
  # exists", not "this exact wording exists".
  RECIPE_HEADING = /^##+ .*1Password.*(?:down|unreachable).*mint/i

  def read(rel) = File.read(File.join(ROOT, rel))

  # An app id is a bare integer. Accept 6-9 digits so a future app registered in
  # a different id era still parses.
  def ids_on_lines_naming(text, item)
    text.lines.select { |line| line.include?(item) }
        .flat_map { |line| line.scan(/(?<!\d)(\d{6,9})(?!\d)/) }
        .flatten.uniq
  end

  # ── 1. BOTH IDS ARE RECORDED, EACH BESIDE THE ITEM IT BELONGS TO ────────────
  #
  # Beside the item, not merely present in the file: a loose number somewhere in
  # a credentials doc is not something an operator mid-outage can act on.
  def test_the_inventory_records_an_app_id_for_each_github_app_item
    inventory = read(INVENTORY)

    ITEMS.each do |item|
      ids = ids_on_lines_naming(inventory, item)
      refute_empty ids,
        "#{INVENTORY} names `#{item}` but records no numeric app-id on any line " \
        "that names it. That is the 2026-08-30 defect exactly: without the id, " \
        "the hand-mint fallback for a 1Password outage needs 1Password."
      assert_equal 1, ids.size,
        "#{INVENTORY} associates #{ids.size} different ids with `#{item}` " \
        "(#{ids.join(', ')}). An operator mid-outage cannot pick between them."
    end
  end

  # ── 2. THE TWO IDS ARE DISTINCT ─────────────────────────────────────────────
  #
  # The lanes are deliberately separate identities; one id copy-pasted onto both
  # rows would send a ship lane to the build App, which has no `secrets` grant.
  def test_the_two_lanes_do_not_share_an_app_id
    inventory = read(INVENTORY)
    agent, deployer = ITEMS.map { |i| ids_on_lines_naming(inventory, i) }

    refute_equal agent, deployer,
      "both App items are recorded with the same app-id #{agent.inspect}; the " \
      "agent and deployer are separate identities with different grants."
  end

  # ── 3. THE SOP AND THE INVENTORY DO NOT DRIFT ───────────────────────────────
  #
  # Two docs holding the same number is the price of the recipe being readable
  # where it is run. This is what keeps that price from being paid in a wrong
  # number six months from now.
  def test_every_app_id_the_sop_hands_to_the_minter_is_one_the_inventory_records
    recorded = ITEMS.flat_map { |i| ids_on_lines_naming(read(INVENTORY), i) }.uniq
    used     = read(SOP).scan(/GH_APP_ID=(\d+)/).flatten.uniq

    refute_empty used,
      "#{SOP} never passes GH_APP_ID a literal id, so its hand-mint recipe " \
      "still cannot be run without looking the number up in 1Password."
    (used - recorded).each do |orphan|
      flunk "#{SOP} mints with app-id #{orphan}, which #{INVENTORY} does not " \
            "record against any item. The docs have drifted."
    end
  end

  # ── 4. THE RECIPE MUST NOT ROUTE BACK THROUGH 1PASSWORD ─────────────────────
  #
  # The whole point of the section is that it works when `op` does not. A
  # well-meaning "use the helper instead" edit restores the circularity while
  # leaving the section looking correct.
  def test_the_hand_mint_recipe_reaches_no_1password
    block = recipe_block

    assert_match(/GH_APP_ID=\d+/, block,
      "the hand-mint recipe must pass a literal app id — that is the half that " \
      "used to be unavailable.")
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

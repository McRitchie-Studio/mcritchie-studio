require "test_helper"

# [integration] db/seeds/59_credentials.rb against the database: AWS was retired
# on 2026-10-10 (object storage on Cloudflare R2, mail on Resend, the IAM users
# and SES identities deleted), so the catalog must stop presenting the three dead
# items as live credentials, on a fresh database AND on one seeded before.
#
# The second case is the one that bites: the seed is an upsert that keeps any
# column a row leaves out, so a retired row that merely drops `used_by` would
# keep telling /credentials the dead key serves "App email delivery".
class CredentialsSeedTest < ActiveSupport::TestCase
  RETIRED_AWS = [
    %w[studio-agents agent.aws],
    %w[studio-agents agent.aws.mcritchie-ses],
    %w[studio-applications mcritchie-industries.aws]
  ].freeze

  def seed!
    capture_io { load Rails.root.join("db/seeds/59_credentials.rb").to_s }
  end

  def record(vault, title)
    CredentialRecord.find_by!(credential_vault_slug: vault, title: title)
  end

  test "the three dead AWS items are retired on a fresh database" do
    seed!

    RETIRED_AWS.each do |vault, title|
      row = record(vault, title)
      assert_equal "retired", row.status, "#{vault}/#{title}"
      refute row.live?
      assert_match(/Retired 2026-10-10/, row.notes)
    end
  end

  test "a row seeded live before is retired in place, with its live claims cleared" do
    seed!
    RETIRED_AWS.each do |vault, title|
      record(vault, title).update!(status: "filed", used_by: "App email delivery",
                                   scope_summary: "General AWS API credentials: S3 read and write, us-east-2.", notes: nil)
    end

    seed!

    RETIRED_AWS.each do |vault, title|
      row = record(vault, title)
      assert_equal "retired", row.status, "#{vault}/#{title}"
      assert_nil row.used_by, "#{title}: a dead key serves nothing"
      assert_nil row.scope_summary, "#{title}: a dead key permits nothing"
    end
    assert_equal 1, CredentialRecord.where(title: "agent.aws").count, "updated in place, never duplicated"
  end

  # The admin item is kept on purpose: the operator's read-only foothold in the
  # AWS account. It is the ONLY live AWS credential the catalog may show.
  test "the admin AWS item is the only live AWS credential" do
    seed!

    live = CredentialRecord.where(service: "aws").select(&:live?).map { |r| [r.credential_vault_slug, r.title] }
    assert_equal [%w[studio-agents-admin AWS]], live
    assert_match(/ViewOnlyAccess/, record("studio-agents-admin", "AWS").scope_summary)
  end

  # The upsert keys on title, so a retitled item would leave its old row behind
  # as an orphan unless the seed renames that row first.
  test "a retitled wallet item is renamed in place, never left as an orphan" do
    seed!
    CredentialRecord.where(title: %w[agent.mack.solana solana.mack.agent]).delete_all
    old = CredentialRecord.create!(credential_vault_slug: "studio-agents", title: "agent.mack.solana",
                                   service: "solana", status: "filed")

    seed!

    assert_equal 0, CredentialRecord.where(title: "agent.mack.solana").count, "the old title is gone"
    assert_equal old.id, record("studio-agents", "solana.mack.agent").id, "renamed in place, not re-created"
    assert record("studio-agents", "solana.turf.alex"), "phantom.turf is filed under its new title"
  end

  # The Turf wallet rows restate credential-inventory.md as corrected on
  # 2026-10-24 (task devnet-nightly-reference-sweep): solana.turf.alex is Alex's
  # personal wallet, misfiled in the agent vault; the rehearsal player is
  # solana.turf.agent. A database seeded before, which told /credentials the
  # personal wallet was the rehearsal player, is corrected in place.
  test "the Turf wallet rows name each wallet's true owner and role" do
    seed!
    record("studio-agents", "solana.turf.alex").update!(
      scope_summary: "The QA contest rehearsal's test player (39QT…, regal-parsley). Devnet test USDC only.",
      used_by: "QA rehearsal"
    )

    seed!

    alex = record("studio-agents", "solana.turf.alex")
    assert_match(/personal Turf wallet \(DKbv…\)/, alex.scope_summary)
    refute_match(/39QT|rehearsal/i, alex.scope_summary, "the personal wallet is not the rehearsal player")
    assert_nil alex.used_by, "no agent lane reads Alex's own wallet"
    assert_match(/MISFILED.*private vault/, alex.notes)

    player = record("studio-agents", "solana.turf.agent")
    assert_match(/test player \(39QT…/, player.scope_summary)
    assert_equal "filed", player.status

    assert_match(/devnet seat 8UwJ…/, record("studio-agents", "solana.mack.agent").scope_summary)
    assert_match(/mainnet \(7auwTL…\)/, record("studio-agents", "solana.turf.system").scope_summary)
    assert_match(/devnet and QA \(2eGs…\)/, record("studio-agents", "solana.turf.system.devnet").scope_summary)

    admin = record("studio-agents", "solana.turf.admin")
    assert_equal "retired", admin.status, "solana.turf.admin was archived 2026-10-09"
    assert_nil admin.scope_summary
  end

  # This repo is PUBLIC: a Solana secret key is 64 bytes, 87-88 base58 chars. A
  # wallet row may carry a truncated public address, never anything key-length.
  test "no wallet row carries anything shaped like a secret key" do
    seed!

    CredentialRecord.where(service: "solana").find_each do |row|
      text = [row.scope_summary, row.notes, row.used_by].compact.join(" ")
      refute_match(/[1-9A-HJ-NP-Za-km-z]{60,}/, text, "#{row.title} carries a key-length base58 string")
    end
  end
end

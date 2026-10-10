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
end

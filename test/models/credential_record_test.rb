require "test_helper"

# [unit] CredentialRecord — a record NAMES a credential and never holds one.
# There is no value column; the secret-shape check below is the tripwire for
# the likeliest leak, a token pasted into a note from the wrong window.
class CredentialRecordTest < ActiveSupport::TestCase
  setup do
    @vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
  end

  def record(**attrs)
    CredentialRecord.new({ credential_vault: @vault, title: "heroku.studio.agents", service: "heroku" }.merge(attrs))
  end

  test "a plain record is valid and has no column that could hold a value" do
    assert record.valid?
    refute_includes CredentialRecord.column_names, "value"
    refute_includes CredentialRecord.column_names, "secret"
  end

  test "every known secret shape is refused, in every text column" do
    samples = {
      "1Password service-account token" => "ops_#{'a' * 30}",
      "GitHub token" => "ghp_#{'A' * 36}",
      "API secret key" => "sk-ant-#{'x' * 30}",
      "AWS access key id" => "AKIA#{'B' * 16}",
      "Slack token" => "xoxb-#{'1' * 12}",
      "private key" => "-----BEGIN OPENSSH PRIVATE KEY-----"
    }
    assert_equal CredentialRecord::SECRET_SHAPES.keys.sort, samples.keys.sort, "every shape needs a sample here"

    samples.each do |label, secret|
      CredentialRecord::TEXT_COLUMNS.each do |column|
        bad = record(column => "pasted #{secret} by mistake")
        refute bad.valid?, "#{label} in #{column} must be refused"
        assert_match(/never holds one/, bad.errors[column].join)
      end
    end
  end

  test "prose that merely mentions a token kind passes" do
    assert record(notes: "The ops_ token lives in ~/.zprofile.admin; rotate the sk- key yearly.").valid?
  end

  test "the service must be a software in config/workspace_icons.yml, so every row has an icon" do
    bad = record(service: "myspace")

    refute bad.valid?
    assert_match(/not a software/, bad.errors[:service].first)
  end

  test "served_entity is the record's own entity when set, else its vault's" do
    assert_equal "studio", record.served_entity
    assert_equal "turf-monster", record(entity: "turf-monster").served_entity,
                 "the Turf Monster keys live in the Studio vault but serve Turf"
    refute record(entity: "atlantis").valid?
  end

  test "live means filed or empty; retired and missing are not" do
    assert record(status: "filed").live?
    assert record(status: "empty").live?
    refute record(status: "retired").live?
    refute record(status: "missing").live?
    refute record(status: "lost").valid?
  end

  test "conventional? recognises <service>.<entity>.<lane>" do
    assert record.conventional?
    refute record(title: "agent.helius").conventional?
    refute record(title: "Coinbase Developer Platform").conventional?
  end

  test "a title is unique within its vault" do
    record.save!

    refute record.valid?
  end
end

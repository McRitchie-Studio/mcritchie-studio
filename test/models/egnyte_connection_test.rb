require "test_helper"
require "support/egnyte_connect_fakes"

# [unit] EgnyteConnection: one Egnyte domain the hub reaches, as the sign-in
# stores it: the domain an admin typed, normalized to the label before
# .egnyte.com; both tokens encrypted; the access token's expiry; and the pair
# each refresh replaces. Every token and domain here is synthetic.
class EgnyteConnectionTest < ActiveSupport::TestCase
  include EgnyteConnectFakes

  ACCESS = "egnyte-synthetic-access-0001".freeze
  REFRESH = "egnyte-synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 11, 6, 18, 0, 0)

  def grant(**over) = egnyte_grant(access_token: ACCESS, refresh_token: REFRESH, **over).transform_keys(&:to_s)

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a typed domain normalizes to the label before .egnyte.com, and anything else is refused" do
    { "example" => "example", " Example.Egnyte.com " => "example", "https://example.egnyte.com/app/index.do#x" => "example",
      "my-co2" => "my-co2" }.each { |typed, domain| assert_equal domain, EgnyteConnection.normalize_domain(typed), typed }
    [ nil, "", "-x", "x-", "a.b", "evil.com/", "example.egnyte.com.evil.com", "a b", "x" * 64, "ex_ample", "@evil" ].each do |typed|
      assert_nil EgnyteConnection.normalize_domain(typed), typed.inspect
    end
  end

  test "[unit] connection stores both tokens as ciphertext at rest, with the access token's expiry" do
    connection = EgnyteConnection.store!(grant, domain: "Example.egnyte.com", username: "alex", by: "alex", now: NOW)
    raw = EgnyteConnection.connection.select_one("SELECT access_token, refresh_token FROM egnyte_connections WHERE id = #{connection.id}")

    assert_equal "example", connection.domain
    assert_equal "example.egnyte.com", connection.host
    assert_not_includes raw["access_token"], ACCESS
    assert_not_includes raw["refresh_token"], REFRESH
    connection.reload
    assert_equal [ ACCESS, REFRESH ], [ connection.access_token, connection.refresh_token ]
    assert_equal NOW + 30.days, connection.access_expires_at, "Egnyte's 2592000 seconds"
    assert_equal [ "alex", NOW, nil ], [ connection.username, connection.connected_at, connection.last_refreshed_at ]
  end

  test "[unit] an inspect masks both tokens" do
    connection = EgnyteConnection.store!(grant, domain: "example", username: "alex", by: "alex", now: NOW)

    assert_not_includes connection.inspect, ACCESS
    assert_not_includes connection.inspect, REFRESH
    assert_includes connection.inspect, 'domain: "example"' # the control: inspect does print this row
  end

  test "[unit] signing the same domain in again replaces its tokens, one row per domain; another domain is its own row" do
    EgnyteConnection.store!(grant, domain: "example", username: "alex", by: "alex", now: NOW)
    second = EgnyteConnection.store!(grant(access_token: "second"), domain: "EXAMPLE.egnyte.com", username: "alex", by: "alex", now: NOW + 1.hour)
    EgnyteConnection.store!(grant, domain: "other", username: nil, by: "alex", now: NOW)

    assert_equal 2, EgnyteConnection.count
    assert_equal "second", second.reload.access_token
    assert_equal %w[example other], EgnyteConnection.readable.map(&:domain)
  end

  test "[unit] an answer with no access token, or a domain that is not one, is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      EgnyteConnection.store!(grant(access_token: nil), domain: "example", username: nil, by: "alex")
    end
    assert_match(/Access token/, error.message)
    assert_raises(ActiveRecord::RecordInvalid) { EgnyteConnection.store!(grant, domain: "evil.com/x", username: nil, by: "alex") }
    assert_equal 0, EgnyteConnection.count
  end

  test "[unit] a grant with no positive lifetime never expires; a refresh token is optional" do
    connection = EgnyteConnection.store!(grant(expires_in: -1, refresh_token: nil), domain: "example", username: nil, by: "alex", now: NOW)

    assert_nil connection.access_expires_at
    assert_nil connection.refresh_token
    assert connection.access_fresh?(NOW + 10.years)
  end

  test "[unit] the access token is fresh until the margin before its expiry" do
    connection = EgnyteConnection.store!(grant, domain: "example", username: nil, by: "alex", now: NOW)

    assert connection.access_fresh?(NOW + 28.days)
    assert_not connection.access_fresh?(NOW + 29.days + 1.minute), "inside the one-day margin"
  end

  test "[unit] a refresh rotates the pair and stamps it; a blank refresh token keeps the stored one" do
    connection = EgnyteConnection.store!(grant, domain: "example", username: nil, by: "alex", now: NOW)
    connection.rotate!({ "access_token" => "a2", "refresh_token" => "r2", "expires_in" => 2_592_000 }, now: NOW + 29.days)
    connection.reload
    assert_equal [ "a2", "r2", NOW + 59.days, NOW + 29.days ],
                 [ connection.access_token, connection.refresh_token, connection.access_expires_at, connection.last_refreshed_at ]

    connection.rotate!({ "access_token" => "a3", "expires_in" => 60 }, now: NOW + 30.days)
    assert_equal [ "a3", "r2" ], [ connection.reload.access_token, connection.refresh_token ]
    assert_raises(ArgumentError) { connection.rotate!({ "refresh_token" => "r4" }) }
    assert_equal "a3", connection.reload.access_token, "a refused rotation stores nothing"
  end

  test "[unit] a row stored under another key is unreadable, skipped, and replaced by the next sign-in" do
    old = EgnyteConnection.store!(grant, domain: "example", username: nil, by: "alex", now: NOW)
    assert old.readable? # the control
    assert_equal [ old ], EgnyteConnection.readable

    with_other_encryption_key do
      assert_not EgnyteConnection.find(old.id).readable?
      assert_empty EgnyteConnection.readable
      assert_no_difference -> { EgnyteConnection.count } do
        EgnyteConnection.store!(grant(access_token: "fresh"), domain: "example", username: nil, by: "alex", now: NOW + 1.hour)
      end
      row = EgnyteConnection.sole
      assert_not_equal old.id, row.id
      assert_equal "fresh", row.access_token
    end
  end
end

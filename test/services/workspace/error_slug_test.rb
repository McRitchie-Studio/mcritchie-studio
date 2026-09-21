require "test_helper"

# [unit] Workspace::ErrorSlug — the rule for what an exception may leave behind
# in a durable column or a terminal. The property under test is a NEGATIVE one,
# so every case here checks that the prose did NOT survive.
class WorkspaceErrorSlugTest < ActiveSupport::TestCase
  SECRET = "-----BEGIN PRIVATE KEY-----MIIEvQIBADANBgkqh".freeze

  test "a raw message never survives, however alarming its contents" do
    error = StandardError.new("credential rejected: #{SECRET}")

    slug = Workspace::ErrorSlug.for(error)

    # The leading word survives as the fault token — that is the point of the
    # token. What must NOT survive is the key, and the character class plus the
    # length bound are what stop it.
    assert_equal "StandardError: credential", slug
    refute_includes slug, "BEGIN PRIVATE KEY"
    refute_includes slug, "MIIEvQ"
  end

  test "a message that LEADS with key bytes still cannot spill them" do
    error = StandardError.new("MIIEvQIBADANBgkqhkiGw0BAQEFAASCBKcwggSjAgEAAoIBAQ rejected")

    slug = Workspace::ErrorSlug.for(error)

    assert_equal "StandardError", slug, "a run longer than a token is not a token"
  end

  test "Google's own error slug is kept — it is the diagnosis" do
    error = StandardError.new(%({"error": "unauthorized_client", "error_description": "long prose about team@client.test"}))

    slug = Workspace::ErrorSlug.for(error)

    assert_includes slug, "unauthorized_client"
    refute_includes slug, "team@client.test", "the description carries addresses we do not spread"
    refute_includes slug, "long prose"
  end

  test "a reason slug is read too" do
    assert_includes Workspace::ErrorSlug.for(StandardError.new(%({"reason": "notFound"}))), "notFound"
  end

  test "an injected slug that is not slug-shaped is refused, not echoed" do
    # The slug is vendor-controlled text. If it does not look like a slug it is
    # not treated as one, so a crafted body cannot smuggle prose through.
    error = StandardError.new(%({"error": "#{SECRET}"}))

    slug = Workspace::ErrorSlug.for(error)

    assert_equal "StandardError", slug
    refute_includes slug, "BEGIN PRIVATE KEY"
  end

  # A NAMED class: an anonymous one stringifies as #<Class:0x...> because
  # "#{error.class}" calls to_s, which an overridden `name` does not touch.
  class FakeServerError < StandardError
    def status_code = 503
  end

  test "an HTTP status stands in when there is no slug" do
    # Leads with a digit, so there is no token to take and the status is all
    # that is left to say.
    slug = Workspace::ErrorSlug.for(FakeServerError.new("503 from upstream for team@client.test"))

    assert_equal "WorkspaceErrorSlugTest::FakeServerError: HTTP 503", slug
    refute_includes slug, "team@client.test"
  end

  test "output is bounded" do
    long = Class.new(StandardError) { def self.name = "E" * 500 }

    assert_operator Workspace::ErrorSlug.for(long.new("x")).length, :<=, Workspace::ErrorSlug::MAX
  end

  test "nil is an answer, not a crash" do
    assert_equal "unknown error", Workspace::ErrorSlug.for(nil)
  end
end

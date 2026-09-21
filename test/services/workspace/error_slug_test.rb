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

  # `#{error.class}` interpolates through to_s, NOT name — and an anonymous
  # class's to_s is `#<Class:0x…>` whatever you define `self.name` to be. The
  # earlier version of this test overrode `self.name` and produced a 30-char
  # slug against a MAX of 120, so it asserted 30 <= 120 and passed with the
  # clamp deleted. Override to_s, and assert the clamp RAN rather than that the
  # result happens to fit.
  test "output is bounded" do
    long = Class.new(StandardError) { def self.to_s = "E" * 500 }

    slug = Workspace::ErrorSlug.for(long.new("x"))

    assert_operator slug.length, :<=, Workspace::ErrorSlug::MAX
    assert_equal Workspace::ErrorSlug::MAX, slug.length,
                 "the subject must be LONGER than MAX, or this test passes without the clamp running"
  end

  # THE REGRESSION THIS CLASS INTRODUCED, pinned. Every caller of ErrorSlug.for
  # is inside a RESCUE BODY, and a raise there is not caught by its own rescue —
  # it escapes and abandons the sweep, which is the exact failure the task
  # exists to remove. A regex over a string with invalid encoding raises
  # ArgumentError, and a garbled or proxy-intercepted response body is how you
  # get one.
  test "an invalidly-encoded message does not raise — it is scrubbed" do
    garbled = StandardError.new("boom \xFF bad".dup.force_encoding("UTF-8"))

    refute garbled.message.valid_encoding?, "the control: the subject must really be invalid UTF-8"

    slug = nil
    assert_nothing_raised { slug = Workspace::ErrorSlug.for(garbled) }
    assert_equal "StandardError: boom", slug
  end

  # OUR OWN ERRORS KEEP THEIR REMEDY. The danger is an exception that quotes its
  # INPUT; an authored message quotes nothing and was written to tell the
  # operator what to do next. Slugging one leaves "refusing", which says nothing.
  test "an authored error passes its remedy through, a foreign one does not" do
    ours = Workspace::Credentials::UnregisteredSubject.new(
      "refusing to impersonate team@x.test: it is not an ACTIVE workspace_account. " \
      "Register the workspace, have its super-admin grant delegation, then run workspace:check."
    )
    theirs = StandardError.new(%({"error": "unauthorized_client", "detail": "team@secret.test"}))

    assert_includes Workspace::ErrorSlug.for(ours), "Register the workspace",
                    "an authored remedy must survive — slugging it leaves the operator nothing to do"
    assert_operator Workspace::ErrorSlug.for(ours).length, :<=, Workspace::ErrorSlug::AUTHORED_MAX

    assert_equal "StandardError: unauthorized_client", Workspace::ErrorSlug.for(theirs),
                 "a FOREIGN message is still reduced to its token — the split is by origin, not by shape"
  end

  test "nil is an answer, not a crash" do
    assert_equal "unknown error", Workspace::ErrorSlug.for(nil)
  end
end

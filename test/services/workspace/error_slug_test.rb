require "test_helper"

# [unit] Workspace::ErrorSlug — the rule for what an exception may leave behind
# in a durable column or a terminal. The property under test is a NEGATIVE one,
# so every case here checks that the prose did NOT survive.
class WorkspaceErrorSlugTest < ActiveSupport::TestCase
  SECRET = "-----BEGIN PRIVATE KEY-----MIIEvQIBADANBgkqh".freeze

  # EVERY ASSERTION HERE IS PLAIN `assert`/`refute`, DELIBERATELY. minitest's
  # `message()` prepends a custom message and still APPENDS the default one, so
  # `refute_includes` / `assert_includes` dump their HAYSTACK even when you pass
  # your own — and the haystack in this file is the slug, on the exact failure
  # that means the slug carried the secret. A leak test that prints the leak
  # when it catches one is not a leak test. So: no haystack in any message
  # below, and lengths instead of contents. The rule itself is in
  # docs/agents/modules/backend-discipline.md, "Never interpolate an exception
  # message that quotes its input" — this is the same rule applied to a test.

  test "a raw message never survives, however alarming its contents" do
    error = StandardError.new("credential rejected: #{SECRET}")

    slug = Workspace::ErrorSlug.for(error)

    # The leading word survives as the fault token — that is the point of the
    # token. What must NOT survive is the key, and the character class plus the
    # length bound are what stop it.
    assert_equal "StandardError: credential", slug
    refute slug.include?("BEGIN PRIVATE KEY"), "the slug is #{slug.length} chars and carries a PEM header"
    refute slug.include?("MIIEvQ"), "the slug is #{slug.length} chars and carries key body bytes"
  end

  test "a message that LEADS with key bytes still cannot spill them" do
    error = StandardError.new("MIIEvQIBADANBgkqhkiGw0BAQEFAASCBKcwggSjAgEAAoIBAQ rejected")

    slug = Workspace::ErrorSlug.for(error)

    assert_equal "StandardError", slug, "a run longer than a token is not a token"
  end

  test "Google's own error slug is kept — it is the diagnosis" do
    error = StandardError.new(%({"error": "unauthorized_client", "error_description": "long prose about team@client.test"}))

    slug = Workspace::ErrorSlug.for(error)

    assert slug.include?("unauthorized_client"), "the diagnosis was dropped; slug is #{slug.length} chars"
    refute slug.include?("team@client.test"),
           "the slug is #{slug.length} chars and carries an address we do not spread"
    refute slug.include?("long prose"), "the slug is #{slug.length} chars and carries description prose"
  end

  test "a reason slug is read too" do
    slug = Workspace::ErrorSlug.for(StandardError.new(%({"reason": "notFound"})))

    assert slug.include?("notFound"), "the reason field was dropped; slug is #{slug.length} chars"
  end

  test "an injected slug that is not slug-shaped is refused, not echoed" do
    # The slug is vendor-controlled text. If it does not look like a slug it is
    # not treated as one, so a crafted body cannot smuggle prose through.
    error = StandardError.new(%({"error": "#{SECRET}"}))

    slug = Workspace::ErrorSlug.for(error)

    assert_equal "StandardError", slug
    refute slug.include?("BEGIN PRIVATE KEY"),
           "a crafted error field smuggled prose through; slug is #{slug.length} chars"
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
    refute slug.include?("team@client.test"), "the slug is #{slug.length} chars and carries an address"
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

    slug = Workspace::ErrorSlug.for(ours)

    assert slug.include?("Register the workspace"),
           "an authored remedy must survive — slugging it leaves the operator nothing to do " \
           "(slug was #{slug.length} chars)"

    assert_equal "StandardError: unauthorized_client", Workspace::ErrorSlug.for(theirs),
                 "a FOREIGN message is still reduced to its token — the split is by origin, not by shape"
  end

  # THE SAME DEFECT THIS FILE ALREADY FIXED FOR `MAX`, ONE BOUND OVER. The
  # AUTHORED_MAX assertion used to ride on the real UnregisteredSubject message,
  # which measures 209 chars against a bound of 400 — so it asserted 209 <= 400
  # and passed with the clamp DELETED. A bound test has to be driven by a
  # subject longer than the bound, or it is a test that the fixture is short.
  test "an authored message is bounded too" do
    long = Workspace::Credentials::UnregisteredSubject.new("R" * (Workspace::ErrorSlug::AUTHORED_MAX * 2))

    slug = Workspace::ErrorSlug.for(long)

    assert_equal Workspace::ErrorSlug::AUTHORED_MAX, slug.length,
                 "the subject must be LONGER than AUTHORED_MAX, or this passes without the clamp running"
    assert_operator Workspace::ErrorSlug::AUTHORED_MAX, :>, Workspace::ErrorSlug::MAX,
                    "two bounds for two threat models — if they converge, one of them is dead code"
  end

  test "nil is an answer, not a crash" do
    assert_equal "unknown error", Workspace::ErrorSlug.for(nil)
  end
end

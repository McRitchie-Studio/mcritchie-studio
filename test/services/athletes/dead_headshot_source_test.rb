require "test_helper"
require "open-uri"
require "stringio"
# `gem "aws-sdk-s3", require: false` in the Gemfile, and the one place the app
# loads it is Studio::S3 — which this unit never reaches. Required here so the
# credential failure below is the REAL exception class the uploader raises, not a
# stand-in that would pass a classifier keyed on anything looser.
require "aws-sdk-s3"

# [unit] THE CLASSIFIER THAT KEEPS A DEAD SOURCE OUT OF THE LANE'S VERDICT.
#
# The whole point of this object is that it answers DIFFERENTLY for two
# exceptions that used to land in one counter, so every test below has the twin
# that would pass against a stub returning a constant. A predicate that answered
# `true` for everything would clear the abort and also swallow a real credential
# failure — which is the exact defect on the other side of this fix — so the
# refusals here are load-bearing, not decoration.
class Athletes::DeadHeadshotSourceTest < ActiveSupport::TestCase
  DHS = Athletes::DeadHeadshotSource

  # ─── the statuses a dead source answers with ────────────────────────────────

  # MEASURED ON PRODUCTION'S OWN FIVE URLs, 2026-09-27, fetched the way
  # Studio::ImageCache.fetch_remote fetches — `URI.open(url, read_timeout: 30,
  # redirect: true)`. Every one answered `["404", "Not Found"]`; a control
  # espn_id answered 230,577 bytes through the same call, so the 404 is a fact
  # about those URLs and not about how Ruby asks.
  test "a 404 from the source is a dead source" do
    assert DHS.dead?(http_error("404", "Not Found"))
    assert_equal 404, DHS.status(http_error("404", "Not Found"))
  end

  # NOT MEASURED, AND THE COMMENT SAYS SO. 410 is here on the protocol's word: it
  # states more definitely what 404 states, and a CDN that switches to it for a
  # retired photo must not resurrect the false abort.
  test "a 410 from the source is a dead source" do
    assert DHS.dead?(http_error("410", "Gone"))
  end

  # ─── the statuses that are still the lane's problem ─────────────────────────

  # A SUSTAINED 5xx IS A RUN THAT DID NOT DO ITS WORK, and it is transient, so a
  # red that clears on the next run is honest. Excusing it would make the lane
  # silent through an ESPN outage.
  test "a 503 from the source is NOT a dead source" do
    refute DHS.dead?(http_error("503", "Service Unavailable"))
    assert_equal 503, DHS.status(http_error("503", "Service Unavailable")),
                 "the status is still READ — it is what the verdict names as the cause"
  end

  # A 403 IS AS LIKELY TO BE US AS ESPN — a blocked user agent reads identically
  # to an empty shelf from here, and guessing wrong in this direction hides a
  # lane that fetches nothing.
  test "a 403 from the source is NOT a dead source" do
    refute DHS.dead?(http_error("403", "Forbidden"))
  end

  # ─── the exceptions that are unambiguously ours ─────────────────────────────

  # THE DEFECT ON THE OTHER SIDE. This is the exception a wholesale credential
  # failure raises, and the reason the predicate may not answer `true` broadly:
  # the rule `failed > cached` is the only thing that catches it.
  test "a missing-credentials error is NOT a dead source" do
    refute DHS.dead?(Aws::Errors::MissingCredentialsError.new(nil, "no creds"))
    assert_nil DHS.status(Aws::Errors::MissingCredentialsError.new(nil, "no creds"))
  end

  # cache! raises a bare ArgumentError with no source_url, and ImageCache.create!
  # raises ActiveRecord::RecordInvalid. Neither is ESPN's fault.
  test "an ordinary error is NOT a dead source" do
    refute DHS.dead?(ArgumentError.new("either source_url or source_path is required"))
    refute DHS.dead?(StandardError.new("404 Not Found"))
  end

  # THE MESSAGE IS NOT THE STATUS, and this is the case that separates reading
  # `io.status` from parsing the message. A StandardError whose message happens to
  # read "404 Not Found" is not a source answering, and a classifier that scanned
  # the message would call it dead and silence a real failure.
  test "a non-HTTP error whose message merely reads like a 404 is NOT a dead source" do
    refute DHS.dead?(StandardError.new("404 Not Found")),
           "the status line is the protocol; a message is whatever a server or a " \
           "rescue wrote, so only one of the two may decide a verdict"
  end

  # ─── the malformed cases, which must fail SAFE ──────────────────────────────

  # AN UNREADABLE STATUS COUNTS AS A FAILURE, not as a dead source. The cost of a
  # wrong nil is a red run an operator investigates; the cost of a wrong 404 is a
  # real upload failure nobody is ever told about.
  test "an HTTP error carrying no readable status is NOT a dead source" do
    io = StringIO.new("")
    io.extend(OpenURI::Meta)
    error = OpenURI::HTTPError.new("something went wrong", io)

    assert_nil DHS.status(error)
    refute DHS.dead?(error), "unreadable must fail into the graded counter, never out of it"
  end

  private

  # The genuine object open-uri raises, built the way open-uri builds it. A double
  # responding only to `message` would pass a message-scanning classifier and
  # prove nothing about this one.
  def http_error(status, reason)
    io = StringIO.new("")
    io.extend(OpenURI::Meta)
    io.status = [status, reason]
    OpenURI::HTTPError.new("#{status} #{reason}", io)
  end
end

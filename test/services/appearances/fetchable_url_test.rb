require "test_helper"
require_relative "../../support/url_guard_world"

# WHAT THE HUB WILL FILE AS A PICTURE AN OPERATOR'S BROWSER LOADS.
#
# `ok?` is the engine's SSRF opinion (http or https, no internal host). `https?`
# is the stricter one the person page's attach uses: the URL is rendered into an
# admin's page and handed out as a swap reference, so it must also be https.
class Appearances::FetchableUrlTest < ActiveSupport::TestCase
  include UrlGuardWorld

  Fetchable = Appearances::FetchableUrl

  test "https? accepts an https URL on a public host" do
    assert Appearances::FetchableUrl.https?("https://cdn.example.com/sheets/a.png")
    assert Appearances::FetchableUrl.https?("HTTPS://CDN.example.com/a.png?x=1")
    assert Appearances::FetchableUrl.https?("https://93.184.216.34/a.png")
  end

  test "https? refuses javascript, data and file URLs" do
    ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:image/png;base64,QUJD", "data:text/html,<script>1</script>",
     "file:///etc/passwd", "ftp://cdn.example.com/a.png", "blob:https://cdn.example.com/1"].each do |url|
      assert_not Appearances::FetchableUrl.https?(url), "expected #{url.inspect} refused"
    end
  end

  test "https? refuses plain http, which ok? allows" do
    assert Appearances::FetchableUrl.ok?("http://cdn.example.com/a.png"), "the control: the engine guard takes http"
    assert_not Appearances::FetchableUrl.https?("http://cdn.example.com/a.png")
  end

  test "https? refuses internal, loopback, private and link-local hosts" do
    ["https://localhost/a.png", "https://LOCALHOST:3000/a.png", "https://printer.local/a.png", "https://hub.internal/a.png",
     "https://nas.lan/a.png", "https://127.0.0.1/a.png", "https://10.0.0.5/a.png", "https://172.16.4.4/a.png",
     "https://192.168.1.1/a.png", "https://169.254.169.254/latest/meta-data", "https://0.0.0.0/a.png",
     "https://[::1]/a.png", "https://[fe80::1]/a.png", "https://[fd00::1]/a.png"].each do |url|
      assert_not Appearances::FetchableUrl.https?(url), "expected #{url.inspect} refused"
    end
  end

  test "https? refuses a URL with no scheme, no host, or no sense" do
    ["/uploads/a.png", "//cdn.example.com/a.png", "cdn.example.com/a.png", "https:///a.png", "https://", "not a url",
     " https://cdn.example.com/a.png", "https://cdn.example.com/a b.png", "", nil].each do |url|
      assert_not Appearances::FetchableUrl.https?(url), "expected #{url.inspect} refused"
    end
  end

  # ── THE NEXT ENGINE LOOKS THE NAME UP (/tasks/url-guard-off-hot-paths) ──────
  #
  # A lookup is uncached and can take seconds, and a failed one refuses the
  # URL. So the hub asks once per host per request, and tells "could not look
  # it up" apart from "not a public address".

  test "one lookup per host within a request, however many URLs and askers" do
    with_url_guard do |lookups|
      urls = (1..8).map { |i| "https://cdn.example.com/#{i}.png?sig=#{i}" } +
             ["https://CDN.example.com/again.png", "http://cdn.example.com/plain.png", "https://other.example.com/a.png"]
      urls.each { |url| assert Fetchable.ok?(url), url }
      urls.each { |url| Fetchable.https?(url) }
      urls.each { |url| Fetchable.verdict(url) }

      assert_equal %w[cdn.example.com other.example.com], lookups
    end
  end

  test "the memo ends with the request: the next one looks the host up again" do
    with_url_guard do |lookups|
      Fetchable.ok?("https://cdn.example.com/a.png")
      Fetchable.ok?("https://cdn.example.com/b.png")
      assert_equal 1, lookups.size

      # What Rails does between two requests, and between two jobs.
      ActiveSupport::CurrentAttributes.clear_all

      Fetchable.ok?("https://cdn.example.com/a.png")
      assert_equal 2, lookups.size, "a verdict never outlives the request that asked"
    end
  end

  test "a remembered verdict is asked again after its age cap, where no request ends" do
    with_guard_clock do
      with_url_guard do |lookups|
        Fetchable.ok?("https://cdn.example.com/a.png")
        UrlGuardWorld.advance(Fetchable::MEMO_TTL - 1)
        Fetchable.ok?("https://cdn.example.com/a.png")
        assert_equal 1, lookups.size

        UrlGuardWorld.advance(2)
        Fetchable.ok?("https://cdn.example.com/a.png")
        assert_equal 2, lookups.size, "a console or a long job re-asks rather than trusting an old answer"
      end
    end
  end

  test "a host that could not be looked up is unresolved, not refused, and that is remembered too" do
    with_url_guard(unresolved: %w[dead.example.com]) do |lookups|
      assert_equal Fetchable::UNRESOLVED, Fetchable.verdict("https://dead.example.com/a.png")
      assert_equal Fetchable::UNRESOLVED, Fetchable.https_verdict("https://dead.example.com/b.png")
      assert_not Fetchable.ok?("https://dead.example.com/c.png"), "unresolved is still not handed to a fetcher"
      assert_not Fetchable.https?("https://dead.example.com/d.png")
      assert_equal %w[dead.example.com], lookups, "a failed lookup is not retried in the same request"

      assert_equal Fetchable::REFUSED, Fetchable.verdict("https://127.0.0.1/a.png")
      assert_equal Fetchable::REFUSED, Fetchable.https_verdict("http://dead.example.com/a.png"), "plain http is refused on its text"
      assert_equal Fetchable::OK, Fetchable.verdict("https://cdn.example.com/a.png")
    end
  end

  test "a refused scheme is judged on its text and never stands for the host" do
    with_url_guard do |lookups|
      assert_equal Fetchable::REFUSED, Fetchable.verdict("ftp://cdn.example.com/a.png")
      assert_equal Fetchable::REFUSED, Fetchable.https_verdict("http://cdn.example.com/a.png")
      assert_equal [], lookups, "neither refusal needed a lookup"
      assert_equal Fetchable::OK, Fetchable.verdict("https://cdn.example.com/a.png")
      assert_equal Fetchable::REFUSED, Fetchable.verdict("ftp://cdn.example.com/a.png"), "an ok host does not clear another scheme"
    end
  end

  test "on the engine locked today there is no unresolved class, and every answer is ok or refused" do
    with_url_guard(unresolved: %w[dead.example.com], engine: :current) do
      assert_not Studio::ImageCache.const_defined?(:UnresolvedSourceHost, false), "the control: today's engine has no such class"
      assert_equal Fetchable::OK, Fetchable.verdict("https://dead.example.com/a.png"), "today's guard resolves nothing"
      assert_equal Fetchable::REFUSED, Fetchable.verdict("https://localhost/a.png")
      assert_equal Fetchable::REFUSED, Fetchable.https_verdict("http://cdn.example.com/a.png")
      assert Fetchable.https?("https://cdn.example.com/a.png")
    end
  end

  # FIVE DEAD NAMES AT SIX SECONDS EACH IS A HEROKU TIMEOUT. A request gives
  # lookups a budget; once it is spent, a name not yet asked about is answered
  # "could not check" without asking.
  test "a request's lookups stop at its budget, and the rest read as could not check" do
    with_guard_clock do
      hosts = (1..6).map { |i| "slow#{i}.example.com" }
      with_url_guard(unresolved: hosts, slow: hosts.index_with { 6 }) do |lookups|
        Fetchable.limit_lookups(10)
        verdicts = hosts.map { |host| Fetchable.verdict("https://#{host}/a.png") }

        assert_equal %w[slow1.example.com slow2.example.com], lookups, "12 s spent crosses a 10 s budget"
        assert_equal [Fetchable::UNRESOLVED], verdicts.uniq
        assert_equal Fetchable::REFUSED, Fetchable.verdict("https://127.0.0.1/a.png"), "a text refusal costs nothing and still answers"
      end
    end
  end

  # NO STAND-IN: the guard here is whichever engine the hub locks. Past the
  # budget the URL's text is still judged, through the next engine's
  # `resolver: nil` or, on one that takes no such keyword, the plain call.
  test "past the budget the locked engine still refuses on the text, and a name reads as could not check" do
    Fetchable.limit_lookups(0)

    assert_equal Fetchable::REFUSED, Fetchable.verdict("https://127.0.0.1/a.png")
    assert_equal Fetchable::REFUSED, Fetchable.verdict("https://localhost/a.png")
    assert_equal Fetchable::REFUSED, Fetchable.https_verdict("http://cdn.example.com/a.png")
    assert_equal Fetchable::UNRESOLVED, Fetchable.verdict("https://cdn.example.com/a.png")
    assert_equal Fetchable::UNRESOLVED, Fetchable.https_verdict("https://cdn.example.com/a.png")
  end

  test "outside a request there is no budget" do
    with_guard_clock do
      hosts = (1..4).map { |i| "slow#{i}.example.com" }
      with_url_guard(slow: hosts.index_with { 6 }) do |lookups|
        hosts.each { |host| assert Fetchable.ok?("https://#{host}/a.png") }
        assert_equal hosts, lookups
      end
    end
  end

  test "a dropped photograph is logged once per look and host, with no path or query" do
    lines = capture_warnings do
      with_url_guard(unresolved: %w[dead.example.com]) do
        3.times do |i|
          assert_not Fetchable.ok_for?("https://dead.example.com/p#{i}.png?token=secret#{i}", look: "look-abc", what: "chosen reference")
        end
        assert Fetchable.ok_for?("https://cdn.example.com/p.png", look: "look-abc", what: "chosen reference")
        assert_not Fetchable.ok_for?("https://127.0.0.1/p.png", look: "look-abc", what: "chosen reference")

        assert_equal [["chosen reference", "dead.example.com"]], Fetchable.left_out(look: "look-abc")
        assert_equal [], Fetchable.left_out(look: "look-other")
      end
    end

    assert_equal 1, lines.size, lines.inspect
    assert_match(/chosen reference left out of look look-abc: host dead\.example\.com could not be looked up/, lines.first)
    assert_no_match(/secret|token|p0\.png/, lines.first)
  end

  private

  def capture_warnings
    lines = []
    logger = Rails.logger
    recorder = ->(message = nil, &blk) { lines << (message || blk&.call).to_s }
    logger.stub(:warn, recorder) { yield }
    lines.select { |line| line.include?("[fetchable_url]") }
  end
end

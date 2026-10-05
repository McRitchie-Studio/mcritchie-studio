require "test_helper"

# WHAT THE HUB WILL FILE AS A PICTURE AN OPERATOR'S BROWSER LOADS.
#
# `ok?` is the engine's SSRF opinion (http or https, no internal host). `https?`
# is the stricter one the person page's attach uses: the URL is rendered into an
# admin's page and handed out as a swap reference, so it must also be https.
class Appearances::FetchableUrlTest < ActiveSupport::TestCase
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
end

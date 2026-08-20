require "test_helper"

# Does a REAL request come back compressed? The middleware-stack unit test proves
# Rack::Deflater is installed; this proves it actually fires on the page that
# needed it, and stays off for a client that did not ask.
class ResponseCompressionTest < ActionDispatch::IntegrationTest
  test "[integration] a page response is gzipped for a client that accepts it" do
    get deployments_path, headers: { "HTTP_ACCEPT_ENCODING" => "gzip" }

    assert_response :success
    assert_equal "gzip", response.headers["Content-Encoding"]
    # A shared cache must never hand this body to a client that cannot read it.
    assert_includes response.headers["Vary"].to_s, "Accept-Encoding"
  end

  test "[integration] gzip actually shrinks the board, and it still decodes to the page" do
    get deployments_path, headers: { "HTTP_ACCEPT_ENCODING" => "gzip" }
    assert_response :success
    compressed = response.body.bytesize

    get deployments_path, headers: { "HTTP_ACCEPT_ENCODING" => "identity" }
    assert_response :success
    plain = response.body.bytesize

    # Measured on production before this task: 1,109,847 bytes down to 101,476 —
    # 10.9x. The fixture board is far smaller, so assert the DIRECTION and a
    # conservative floor rather than a number that would drift with the fixtures.
    assert_operator compressed, :<, plain / 2,
                    "gzip should at least halve an HTML board (#{compressed}B vs #{plain}B)"

    inflated = Zlib::GzipReader.new(StringIO.new(begin
      get deployments_path, headers: { "HTTP_ACCEPT_ENCODING" => "gzip" }
      response.body
    end)).read
    # The compressed bytes are the SAME page, not a truncated or empty one — a
    # header check alone would pass on a body that never arrived.
    assert_equal plain, inflated.bytesize
    assert_includes inflated, "Deployments"
  end

  test "[integration] a client that sends no Accept-Encoding gets the plain body" do
    get deployments_path, headers: { "HTTP_ACCEPT_ENCODING" => "identity" }

    assert_response :success
    assert_nil response.headers["Content-Encoding"]
    assert_includes response.body, "Deployments"
  end
end

require "test_helper"

# The two wire-level costs on every page view, pinned so they cannot silently
# come back. Measured on production 2026-08-19 before this task: /deployments
# returned 1,109,847 bytes of HTML with no content-encoding, and a cold load
# pulled 7,810,044 bytes of subresources — 7.4MB of which was four agent
# portraits displayed at about 56 pixels.
class ResponsePayloadBudgetTest < ActiveSupport::TestCase
  # Every agent portrait is drawn inside components/_agent_avatar, whose largest
  # size is w-16 (64 CSS px). The sources were 1619x971 and up to 2.5MB each.
  AGENT_IMAGE_BUDGET_BYTES = 50 * 1024

  # The tallest the avatar component ever draws is 64 CSS px, so 192 source pixels
  # covers a 3x display with room to spare. This is a CEILING, not the exact size:
  # it fails on a re-upload of the original artwork, which is the mistake being
  # guarded, and stays quiet on a deliberate smaller crop.
  AGENT_IMAGE_MAX_EDGE = 320

  test "[unit] Rack::Deflater is in the middleware stack" do
    middlewares = Rails.application.middleware.map { |m| m.klass.to_s }

    assert_includes middlewares, "Rack::Deflater",
                    "nothing in front of this app compresses — no CDN, and the Heroku router does not"
  end

  test "[unit] Rack::Deflater sits outside Rack::ETag" do
    middlewares = Rails.application.middleware.map { |m| m.klass.to_s }
    deflater = middlewares.index("Rack::Deflater")
    etag = middlewares.index("Rack::ETag")

    assert deflater, "Rack::Deflater is not in the stack at all"
    assert etag, "Rack::ETag is not in the stack — this test's premise is gone, not its subject"
    # Earlier in the list is OUTER. Outside ETag means the ETag is computed over the
    # uncompressed body, so a conditional GET behaves the same for every client
    # regardless of what it accepts.
    assert deflater < etag,
           "Rack::Deflater must sit outside Rack::ETag, or the ETag describes the compressed bytes"
  end

  test "[unit] every agent portrait stays inside the page-weight budget" do
    images = Dir[Rails.root.join("public/agents/*.png")]
    assert images.any?, "no agent portraits found — this guard would pass vacuously"

    oversized = images.filter_map do |path|
      size = File.size(path)
      "#{File.basename(path)} is #{(size / 1024.0).round}KB" if size > AGENT_IMAGE_BUDGET_BYTES
    end

    assert_empty oversized,
                 "agent portraits are drawn at ~56px and must stay small: #{oversized.join(', ')}"
  end

  test "[unit] every agent portrait stays inside the pixel budget" do
    images = Dir[Rails.root.join("public/agents/*.png")]
    assert images.any?, "no agent portraits found — this guard would pass vacuously"

    # Read the PNG IHDR directly rather than shelling out to an image tool that CI
    # may not carry: bytes 16..23 of a PNG are width then height, big-endian.
    too_big = images.filter_map do |path|
      header = File.binread(path, 24)
      width, height = header[16, 8].unpack("N2")
      next if width.nil? || height.nil?

      "#{File.basename(path)} is #{width}x#{height}" if [width, height].max > AGENT_IMAGE_MAX_EDGE
    end

    assert_empty too_big,
                 "a portrait was re-uploaded at source resolution: #{too_big.join(', ')}"
  end
end

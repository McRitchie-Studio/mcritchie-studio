require "test_helper"

# The two wire-level costs on every page view, pinned so they cannot silently
# come back. Measured on production 2026-08-19 before this task: /deployments
# returned 1,109,847 bytes of HTML with no content-encoding, and a cold load
# pulled 7,810,044 bytes of subresources — 7.4MB of which was four agent
# portraits displayed at about 56 pixels.
class ResponsePayloadBudgetTest < ActiveSupport::TestCase
  # THE LARGEST DRAW IS NOT THE AVATAR. An earlier version of this guard said it
  # was — "every agent portrait is drawn inside components/_agent_avatar, whose
  # largest size is w-16 (64 CSS px)" — and set a 320px ceiling on that premise.
  # The premise was false, and the ceiling would have cemented the regression it
  # let through.
  #
  # The real largest draw is app/views/agents/index.html.erb:16, the PUBLIC agents
  # index, which renders each portrait as a full-bleed card hero: object-cover
  # inside an aspect-[5/3] link. That hero is about 294 CSS px wide on a wide
  # desktop and up to about 608 CSS px at the grid-cols-1 mobile breakpoint. The
  # 5:3 crop is not a coincidence — 1619x971 is exactly that ratio, so these
  # portraits were authored to BE that hero.
  #
  # 768px on the long edge is 2x the desktop hero and covers the mobile case;
  # compared at 608 CSS px on a 2x display, a 768px re-encode is indistinguishable
  # from the 2.4MB source, while 320px was visibly mush.
  AGENT_IMAGE_MAX_EDGE = 768

  # Headroom over the largest current file (~156KB) and still far below a re-upload of the
  # original artwork (2.2-2.7MB), which is the mistake being guarded. Tightened from 256KB
  # when the portraits moved from 8-bit-colormap PNG (196-228KB) to WebP q90 (104-156KB);
  # 200KB is the task's stated budget and still leaves ~28 percent of headroom over the
  # largest file, so an ordinary re-encode does not trip it but a source re-upload does.
  AGENT_IMAGE_BUDGET_BYTES = 200 * 1024

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
    images = portrait_paths
    assert images.any?, "no agent portraits found — this guard would pass vacuously"

    oversized = images.filter_map do |path|
      size = File.size(path)
      "#{File.basename(path)} is #{(size / 1024.0).round}KB" if size > AGENT_IMAGE_BUDGET_BYTES
    end

    assert_empty oversized,
                 "agent portraits must stay inside the page-weight budget: #{oversized.join(', ')}"
  end

  # THE FLOOR, which is the half that was missing. This file only ever had a
  # CEILING, so shrinking the portraits to 320px — below what their largest draw
  # needs — passed every assertion here. A ceiling guards against re-uploading the
  # source; only a floor guards against over-compressing it.
  #
  # Scoped to the 5:3 portraits because that ratio IS the card hero
  # (agents/index.html.erb:16 renders object-cover inside aspect-[5/3], and the
  # 1619x971 sources are exactly 5:3 — they were authored for it). Square files are
  # exempt: alex's source is only 340x340, so demanding 640 of it would demand
  # resolution that has never existed.
  HERO_MIN_LONG_EDGE = 640

  test "[unit] every 5:3 portrait is still big enough for the card hero" do
    too_small = portrait_dimensions.filter_map do |name, (width, height)|
      next if height.zero?
      next unless (width.to_f / height).between?(1.6, 1.75) # ~5:3, the hero ratio

      "#{name} is #{width}x#{height}" if width < HERO_MIN_LONG_EDGE
    end

    assert_empty too_small,
                 "a hero portrait was compressed below what agents/index.html.erb:16 draws: " \
                 "#{too_small.join(', ')}"
  end

  test "[unit] every agent portrait stays inside the pixel budget" do
    too_big = portrait_dimensions.filter_map do |name, (width, height)|
      "#{name} is #{width}x#{height}" if [width, height].max > AGENT_IMAGE_MAX_EDGE
    end

    assert_empty too_big,
                 "a portrait was re-uploaded at source resolution: #{too_big.join(', ')}"
  end
  private

  # Every agent portrait on disk, whatever container it is in. Globbing one extension is how
  # this guard went vacuous once already: the files moved to WebP and `*.png` matched nothing,
  # so `images.any?` was the only thing standing between a silent pass and no coverage at all.
  def portrait_paths
    Dir[Rails.root.join("public/agents/*.{png,webp}")]
  end

  # { basename => [width, height] } for every agent portrait. Reads the header bytes directly
  # rather than shelling out to an image tool CI may not carry.
  def portrait_dimensions
    images = portrait_paths
    assert images.any?, "no agent portraits found — these guards would pass vacuously"

    images.to_h { |path| [File.basename(path), image_dimensions(path)] }
  end

  # PNG: bytes 16..23 are width then height, big-endian, straight out of the IHDR.
  #
  # WebP is a RIFF container and the dimensions sit in a different place in each of its three
  # chunk layouts, so the fourcc at bytes 12..15 has to be read first. Handling only the one
  # cwebp happens to emit today (VP8, simple lossy) would leave this silently wrong the day
  # someone passes -lossless (VP8L) or ships an alpha/animated file (VP8X).
  def image_dimensions(path)
    head = File.binread(path, 32)
    return head[16, 8].unpack("N2").map(&:to_i) if head[0, 8].unpack1("H16") == "89504e470d0a1a0a"

    case head[12, 4]
    when "VP8 "  # simple lossy: 14-bit width then height, little-endian
      [head[26, 2].unpack1("v") & 0x3fff, head[28, 2].unpack1("v") & 0x3fff]
    when "VP8L"  # lossless: 14 bits each, minus one, packed from bit 0
      bits = head[21, 4].unpack1("V")
      [(bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1]
    else         # VP8X extended: 24-bit canvas width then height, each minus one
      [uint24_le(head, 24) + 1, uint24_le(head, 27) + 1]
    end
  end

  # Ruby has no 24-bit unpack directive, so pad to 32 bits and read little-endian.
  def uint24_le(bytes, offset)
    bytes[offset, 3].ljust(4, "\0").unpack1("V")
  end
end

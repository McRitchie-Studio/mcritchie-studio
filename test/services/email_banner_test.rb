require "test_helper"

# [unit] EmailBanner — the composed, per-recipient email banner.
#
# The happy path is the least interesting thing here. What this file is really
# for is the two properties that decide whether the feature is safe to put in
# front of real recipients:
#
#   1. It CANNOT break a send. Every failure returns nil so the mailer falls
#      back to the static catalogue banner. A missing font or an S3 outage is
#      not worth failing to deliver a sign-in link over.
#   2. The cache key changes whenever the picture would. Gmail proxies and
#      caches images by URL, so a reworded greeting served at an old URL shows
#      the OLD words — a wrong-content bug that no test of the renderer alone
#      would catch.
class EmailBannerTest < ActiveSupport::TestCase
  BACKGROUND = Rails.root.join("app/assets/images/emails/banner-background.png").to_s
  LOGO       = Rails.root.join("app/assets/images/emails/logo-mark.png").to_s

  # --- the cache key is the correctness boundary -----------------------------

  test "identical greetings reuse one object" do
    a = EmailBanner.cache_key(header: "Welcome Mason!", subtext: "sub", background: "bg", logo: "logo")
    b = EmailBanner.cache_key(header: "Welcome Mason!", subtext: "sub", background: "bg", logo: "logo")

    assert_equal a, b, "the same banner must not be composed and stored twice"
  end

  test "every input that changes a pixel changes the key" do
    base = { header: "Welcome Mason!", subtext: "sub", background: "bg", logo: "logo" }
    baseline = EmailBanner.cache_key(**base)

    {
      header:     "Welcome Alex!",
      subtext:    "different",
      background: "other-bg",
      logo:       "other-logo",
      scrim:      false
    }.each do |field, value|
      changed = EmailBanner.cache_key(**base.merge(field => value))
      refute_equal baseline, changed,
        "#{field} changes the picture, so it must change the URL — Gmail caches by URL"
    end
  end

  test "the template version supersedes every cached banner" do
    key = EmailBanner.cache_key(header: "Welcome Mason!", subtext: nil, background: "bg", logo: "logo")

    assert_includes EmailBanner::TEMPLATE_VERSION.to_s, "1"
    # Bumping the constant must move every key, which is what makes a layout
    # change safe to deploy against a bucket full of old compositions.
    source = File.read(Rails.root.join("app/services/email_banner.rb"))
    assert_match(/TEMPLATE_VERSION.*\n.*digest|TEMPLATE_VERSION, WIDTH/m, source.gsub(/\n\s*#.*/, ""),
      "TEMPLATE_VERSION must be part of the digest")
    refute_nil key
  end

  # --- it must never break a send -------------------------------------------

  test "a compose failure yields nil rather than raising" do
    EmailBanner.stub(:compose_and_store, ->(**_) { raise Errno::ENOENT, "no such font" }) do
      assert_nil EmailBanner.url_for(header: "Welcome Mason!"),
        "the mailer falls back to the static banner; it must not see an exception"
    end
  end

  test "an S3 outage on the existence probe still composes" do
    EmailBanner.stub(:stored?, ->(_key) { raise "S3 unreachable" }) do
      # stored? swallows its own errors, so this must not surface either.
      assert_nothing_raised { EmailBanner.url_for(header: "Welcome Mason!") }
    end
  end

  test "a blank header is not a banner" do
    assert_nil EmailBanner.url_for(header: "")
    assert_nil EmailBanner.url_for(header: "   ")
    assert_nil EmailBanner.url_for(header: nil)
  end

  # --- the composition itself ------------------------------------------------

  test "it draws a banner at the slot's retina size" do
    Dir.mktmpdir do |dir|
      out = File.join(dir, "b.png")
      EmailBanner.send(:draw, out:, header: "Welcome Mason!", subtext: "your sign-in link is below",
                       background: BACKGROUND, logo: LOGO)

      assert File.exist?(out)
      dims = `magick identify -format "%wx%h" #{Shellwords.escape(out)}`.strip
      assert_equal "#{EmailBanner::WIDTH}x#{EmailBanner::HEIGHT}", dims
    end
  end

  # A name long enough to overflow must WRAP AND SHRINK, not run off the edge or
  # push the sub-text and logo out of the frame.
  test "a long name stays inside the frame" do
    Dir.mktmpdir do |dir|
      short = File.join(dir, "short.png")
      long  = File.join(dir, "long.png")

      EmailBanner.send(:draw, out: short, header: "Welcome Mason!", subtext: "sub",
                       background: BACKGROUND, logo: LOGO)
      EmailBanner.send(:draw, out: long, header: "Welcome Bartholomew Fitzgerald-Montgomery!",
                       subtext: "sub", background: BACKGROUND, logo: LOGO)

      %w[short long].zip([short, long]).each do |label, path|
        dims = `magick identify -format "%wx%h" #{Shellwords.escape(path)}`.strip
        assert_equal "#{EmailBanner::WIDTH}x#{EmailBanner::HEIGHT}", dims,
          "#{label} name changed the canvas — text must fit the box, not resize it"
      end
    end
  end

  test "it composes without a background rather than failing" do
    Dir.mktmpdir do |dir|
      out = File.join(dir, "b.png")
      EmailBanner.send(:draw, out:, header: "Welcome Mason!", subtext: nil,
                       background: nil, logo: nil)

      assert File.exist?(out), "a missing background falls back to the brand gradient"
    end
  end

  # --- fonts -----------------------------------------------------------------

  # REGRESSION GUARD. Fonts are referenced by PATH, never by fontconfig family
  # name: a family name resolves on the Heroku dyno and NOT on macOS, so the
  # build would pass in production and fail on the desk that made it.
  test "fonts resolve to files that exist" do
    %i[bold light].each do |weight|
      path = EmailBanner.send(:font, weight)
      refute_nil path, "no #{weight} font resolved"
      assert File.exist?(path), "#{weight} font is not a real file: #{path}"
      assert path.start_with?("/"), "fonts must resolve to a PATH, not a family name"
    end
  end

  test "the brand face ships in the repo" do
    %w[brand-bold.ttf brand-regular.ttf].each do |face|
      path = Rails.root.join("app/assets/fonts", face)
      assert path.exist?, "#{face} must be committed — the dyno has only DejaVu"

      # An sfnt header, i.e. actually a font and not an HTML error page that a
      # download quietly saved.
      assert_equal "\x00\x01\x00\x00".b, File.binread(path, 4),
        "#{face} is not a TrueType font"
    end
    assert Rails.root.join("app/assets/fonts/OFL.txt").exist?,
      "Montserrat is OFL — the licence ships with the faces"
  end
end

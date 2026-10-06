# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [integration] Export writes the approved header as a file the app commits,
# and prints the catalog registration for it.
class EmailImages::ExportTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    @dir = Dir.mktmpdir("email-image-export")
    @brief = turf_brief
    @jpg = EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600)
    @artifact = Artifact.create!(kind: "email_header", brief_slug: @brief.slug, image_url: @jpg.data_uri)
  end

  teardown { FileUtils.rm_rf(@dir) }

  test "an approved header is written into a directory under its own name" do
    @brief.approve!(@artifact, by: "alex")
    result = EmailImages::Export.call(@brief.reload, into: "#{@dir}/")

    path = File.join(@dir, "drop-signup-confirmation-new-player-banner.jpg")
    assert_equal path, result.path
    assert_equal @jpg.bytes, File.binread(path)
    assert_equal path, @brief.reload.exported_to
    assert @brief.exported_at
    assert_includes result.snippet, "Studio::EmailCatalog.register(\n  \"drop_signup_confirmation_new_player\""
    assert_includes result.snippet, %(default_asset: "emails/drop-signup-confirmation-new-player-banner.jpg")
    assert_includes result.snippet, %(alt: "You're In!")
  end

  test "an exact file path is honoured" do
    @brief.approve!(@artifact, by: "alex")
    path = File.join(@dir, "nested", "custom.jpg")
    EmailImages::Export.call(@brief.reload, into: path)
    assert File.file?(path)
  end

  test "no approved header, no export" do
    assert_raises(EmailImages::Export::NotApproved) { EmailImages::Export.call(@brief, into: @dir) }
  end

  test "bin/email-image export prints the file and the snippet" do
    @brief.approve!(@artifact, by: "alex")
    out = StringIO.new
    err = StringIO.new
    status = EmailImages::Cli.new(["export", @brief.slug, "--into", @dir], out: out, err: err).run

    assert_equal 0, status, err.string
    assert_includes out.string, "wrote #{File.join(@dir, @brief.asset_filename)}"
    assert_includes out.string, "Studio::EmailCatalog.resolved_url"
  end

  test "bin/email-image brief opens a brief" do
    out = StringIO.new
    status = EmailImages::Cli.new(["brief", "--app", "mcritchie-studio", "--email", "magic_link", "--brand",
                                   "mcritchie-studio", "--headline", "Sign in", "--text-mode", "none"], out: out).run
    assert_equal 0, status
    assert EmailImageBrief.find_by(slug: "mcritchie-studio-magic-link-default")&.text_mode == "none"
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] bin/email-image as the `email-image` SOP drives it: every subcommand
# parses its flags, a round records its notes and round number on each
# candidate, the round cap holds through the CLI path, approval needs --by, and
# [integration] an export after a CLI approval writes the asset. The adapter is
# the recorder from EmailImageFakes; nothing is bought, nothing leaves the box.
class EmailImages::CliTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    ImageGeneration::Registry.reload!
    @dir = Dir.mktmpdir("email-image-cli")
  end

  teardown do
    FileUtils.rm_rf(@dir)
    ImageGeneration::Registry.reload!
  end

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = EmailImages::Cli.new(argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  # One record per line: type, subject, then key=value fields.
  def records(text, type)
    text.lines.map { |l| l.chomp.split("\t") }.select { |parts| parts.first == type }.map do |parts|
      fields = parts.drop(2).to_h { |kv| kv.split("=", 2) }
      fields.merge("_subject" => parts[1])
    end
  end

  def jpg_bytes = @jpg_bytes ||= EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600).bytes

  # --- brief ---------------------------------------------------------------

  test "brief opens a brief from flags: headline, subtext, alt, text mode and notes" do
    status, out, = cli("brief", "--app", "turf-monster", "--email", "drop_signup_confirmation",
                       "--variant", "new_player", "--brand", "turf-monster", "--headline", "You're In!",
                       "--subtext", "Picks open Friday", "--alt", "You're in the drop", "--text-mode", "none",
                       "--notes", "gator holds a ticket")

    assert_equal 0, status
    brief = EmailImageBrief.sole
    assert_equal ["You're In!", "Picks open Friday", "You're in the drop", "none", "gator holds a ticket"],
                 [brief.headline, brief.subtext, brief.alt_text, brief.text_mode, brief.prompt_notes]
    assert_equal "bin/email-image", brief.created_by
    created = records(out, "created").sole
    assert_equal brief.slug, created["_subject"]
    assert_equal "/email_images/#{brief.slug}", created["page"]
  end

  test "brief <slug> edits the copy but never the brief's identity" do
    brief = turf_brief

    assert_equal 0, cli("brief", brief.slug, "--headline", "You're on the list", "--max-rounds", "6").first
    assert_equal ["You're on the list", 6], brief.reload.values_at(:headline, :max_rounds)

    status, _, err = cli("brief", brief.slug, "--app", "mcritchie-studio")
    assert_equal 2, status
    assert_match(/identity/, err)
    assert_equal "turf-monster", brief.reload.app
  end

  # --- assets --------------------------------------------------------------

  test "assets writes each reference as a viewable file and prints its public URL" do
    status, out, = cli("assets", "turf-monster", "--out", @dir)

    assert_equal 0, status
    refs = records(out, "reference")
    assert_equal %w[mascot style], refs.map { |r| r["_subject"] }
    refs.each do |r|
      assert File.file?(r["file"]), "#{r['file']} was written"
      assert_includes %w[.png .jpg], File.extname(r["file"]), "a WebP mascot is converted so any viewer opens it"
      assert_match %r{\Ahttps?://[^/]+/}, r["url"]
    end
    assert_equal "#2E7D32", records(out, "palette").find { |p| p["_subject"] == "primary" }["hex"]
    swatch = records(out, "palette").find { |p| p["_subject"] == "swatch" }
    assert File.file?(swatch["file"]), "the palette is shown as colour, not only hex"
    assert_equal 1, records(out, "style").size
  end

  test "assets lists the brand's approved headers and skips other brands" do
    brief = turf_brief
    artifact = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    brief.approve!(artifact, by: "alex")
    other = turf_brief(variant: "existing_player", brand_kit: "mcritchie-studio")
    other_art = Artifact.create!(kind: "email_header", brief_slug: other.slug, image_url: "https://assets.example.test/b.jpg")
    other.approve!(other_art, by: "alex")

    status, out, = EmailImages::Download.stub(:bytes, jpg_bytes) { cli("assets", "turf-monster", "--out", @dir) }

    assert_equal 0, status
    approved = records(out, "approved")
    assert_equal [brief.catalog_key], approved.map { |a| a["_subject"] }
    assert_equal "https://assets.example.test/a.jpg", approved.sole["url"]
    assert File.file?(approved.sole["file"])
  end

  test "assets --no-download writes nothing and still prints the URLs" do
    _, out, = cli("assets", "turf-monster", "--out", @dir, "--no-download")

    assert(records(out, "reference").all? { |r| r["file"] == "-" && r["url"].present? })
    assert_empty Dir.children(@dir)
  end

  test "assets refuses an unknown kit" do
    status, _, err = cli("assets", "acme")
    assert_equal 1, status
    assert_match(/No email brand kit "acme"/, err)
  end

  # --- generate ------------------------------------------------------------

  test "generate runs a round, records its notes and number on each candidate, and downloads them" do
    brief = turf_brief
    status, out, = with_fake_header_generator do
      EmailImages::Download.stub(:bytes, jpg_bytes) do
        cli("generate", brief.slug, "--notes", "make the gator bigger", "--out", @dir)
      end
    end

    assert_equal 0, status
    round = records(out, "round").sole
    assert_equal "1/4", round["round"]
    assert_equal "done", round["state"]
    assert_equal "12200", round["units"]
    assert_equal "unpriced", round["cost"]
    assert_equal "make the gator bigger", round["notes"]

    candidates = records(out, "candidate")
    assert_equal 2, candidates.size
    candidates.each do |c|
      assert_equal "1", c["round"]
      assert_equal "make the gator bigger", c["notes"]
      assert File.file?(c["file"])
    end
    assert(brief.candidates.all? { |a| a.prompt.include?("Round 1 direction: make the gator bigger") })
    assert(EmailImageFakes::Adapter.calls.all? { |c| c[:prompt].include?("make the gator bigger") },
           "the notes reach the model, not just the record")
  end

  test "each round keeps its own notes; show lists them oldest first" do
    brief = turf_brief
    with_fake_header_generator do
      assert_equal 0, cli("generate", brief.slug, "--notes", "first idea", "--no-download").first
      assert_equal 0, cli("generate", brief.slug, "--no-download").first
      assert_equal 0, cli("generate", brief.slug, "--notes", "night sky", "--no-download").first
    end

    _, out, = cli("show", brief.slug, "--no-download")
    shown = records(out, "candidate")
    assert_equal %w[1 1 2 2 3 3], shown.map { |c| c["round"] }
    assert_equal ["first idea", "first idea", "-", "-", "night sky", "night sky"], shown.map { |c| c["notes"] }
    assert_equal "3/4", records(out, "brief").sole["rounds"]
  end

  test "the round cap holds through the CLI: a fifth round is refused and spends nothing" do
    brief = turf_brief
    brief.update_columns(rounds_used: 4, max_rounds: 4)

    status, _, err = with_fake_header_generator { cli("generate", brief.slug) }

    assert_equal 1, status
    assert_match(/all 4 rounds/, err)
    assert_empty EmailImageFakes::Adapter.calls
    assert_equal 4, brief.reload.rounds_used
  end

  test "generate without a key refuses before any claim" do
    brief = turf_brief
    status, _, err = with_env("OPENAI_API_KEY", nil) { cli("generate", brief.slug) }

    assert_equal 1, status
    assert_match(/OPENAI_API_KEY/, err)
    assert_equal 0, brief.reload.rounds_used
  end

  test "a failed round exits 1 with the reason and keeps the brief claimable" do
    brief = turf_brief
    status, _, err = with_fake_header_generator do
      EmailImages::Crop.stub(:call, ->(*, **) { raise EmailImages::Crop::CropFailed, "bad pixels" }) do
        cli("generate", brief.slug, "--no-download")
      end
    end

    assert_equal 1, status
    assert_match(/round 1 failed: .*bad pixels/, err)
    assert_equal "failed", brief.reload.build_state
  end

  test "generate needs a brief slug" do
    status, _, err = cli("generate", "--notes", "x")
    assert_equal 2, status
    assert_match(/name a brief slug/, err)
  end

  # --- approve / retire / export -------------------------------------------

  test "approve requires --by so it can only record a person's word" do
    brief = turf_brief
    artifact = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")

    status, _, err = cli("approve", brief.slug, artifact.slug)
    assert_equal 2, status
    assert_match(/--by is required/, err)
    assert_nil brief.reload.approved_artifact_slug

    status, out, = cli("approve", brief.slug, artifact.slug, "--by", "alex")
    assert_equal 0, status
    assert_equal artifact.slug, brief.reload.approved_artifact_slug
    assert_equal "alex", artifact.reload.approved_by
    assert_equal "alex", records(out, "approved").sole["by"]
  end

  test "approve refuses a candidate of another brief" do
    brief = turf_brief
    other = turf_brief(variant: "existing_player")
    foreign = Artifact.create!(kind: "email_header", brief_slug: other.slug, image_url: "https://assets.example.test/f.jpg")

    status, = cli("approve", brief.slug, foreign.slug, "--by", "alex")
    assert_equal 1, status
    assert_nil foreign.reload.approved_at
  end

  test "retire clears an approval" do
    brief = turf_brief
    artifact = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    brief.approve!(artifact, by: "alex")

    status, out, = cli("retire", brief.slug, artifact.slug)
    assert_equal 0, status
    assert_predicate artifact.reload, :retired?
    assert_nil brief.reload.approved_artifact_slug
    assert_equal "-", records(out, "retired").sole["approved"]
  end

  test "[integration] export after a CLI approval writes the approved asset" do
    brief = turf_brief
    with_fake_header_generator { cli("generate", brief.slug, "--no-download") }
    chosen = brief.candidates.first
    # The stored URL is our bucket's; serve its bytes from the same crop.
    assert_equal 0, cli("approve", brief.slug, chosen.slug, "--by", "alex").first

    status, out, = EmailImages::Download.stub(:bytes, jpg_bytes) { cli("export", brief.slug, "--into", "#{@dir}/") }

    assert_equal 0, status
    path = File.join(@dir, brief.asset_filename)
    assert_equal jpg_bytes, File.binread(path)
    assert_includes out, "wrote #{path}"
    assert_includes out, "Studio::EmailCatalog.register"
    assert_equal path, brief.reload.exported_to
  end
end

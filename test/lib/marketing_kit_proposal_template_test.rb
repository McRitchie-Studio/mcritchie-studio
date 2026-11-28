# frozen_string_literal: true

require "test_helper"
require "zip"
require_relative "../support/marketing_kit_fixtures"

# [unit] MarketingKit::ProposalTemplate (task cw-proposal-page-layout): the Proposal is a Word file Drive converts to
# a Google Doc, because Drive's HTML import drops page breaks. The payload carries every word: detail rows with one
# pricing row holding the breakdown, the client logos image when the spec names one, the brand's terms only when the
# spec has them, and the signature block. The drawn file has one section per page and the two-tone bar in its header
# and footer.
class MarketingKitProposalTemplateTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  BREAKDOWN = ->(d) {
    d["proposal"]["details"] = [["Project", "Project name"], ["Scope / Pricing", "One line of scope"],
                                ["Payment terms", ["Payment of [50%] up front.", "The rest on completion."]]]
    d["proposal"]["pricing_breakdown"] = [{ "category" => "Travel", "items" => %w[Flights Hotel] }, { "category" => "Labor", "items" => [] }]
  }

  test "the default details carry one Pricing-labelled row holding the default breakdown" do
    load_kit do |spec|
      rows = MarketingKit::ProposalTemplate.new(spec).payload[:details]
      priced = rows.select { |r| r[:pricing] }
      assert_equal 1, priced.size
      assert_equal "Scope / Pricing", priced.first[:label]
      assert_equal %w[Materials Labor], priced.first.dig(:pricing, :breakdown).map { |b| b[:category] }.first(2)
      assert_equal "With applicable taxes included:", priced.first.dig(:pricing, :total_label)
    end
  end

  test "the spec's breakdown rides the pricing row; a list value is bullets, a string is one line" do
    load_kit(edit: BREAKDOWN) do |spec|
      rows = MarketingKit::ProposalTemplate.new(spec).payload[:details].index_by { |r| r[:label] }
      assert_equal [{ category: "Travel", items: %w[Flights Hotel] }, { category: "Labor", items: [] }],
                   rows["Scope / Pricing"].dig(:pricing, :breakdown)
      assert rows["Payment terms"][:bullets]
      refute rows["Project"][:bullets]
      assert_equal ["Project name"], rows["Project"][:lines]
    end
  end

  test "with no row naming pricing, a Pricing row goes in after the scope" do
    edit = ->(d) { d["proposal"]["details"] = [["Project", "x"], ["Scope of work", "y"], ["Payment terms", "z"]] }
    load_kit(edit: edit) do |spec|
      labels = MarketingKit::ProposalTemplate.new(spec).payload[:details].map { |r| r[:label] }
      assert_equal ["Project", "Scope of work", "Pricing", "Payment terms"], labels
    end
  end

  test "a one-row details list gets its Pricing row at the end, with no gap" do
    load_kit(edit: ->(d) { d["proposal"]["details"] = [["Project", "x"]] }) do |spec|
      rows = MarketingKit::ProposalTemplate.new(spec).payload[:details]
      assert_equal ["Project", "Pricing"], rows.map { |r| r[:label] }
    end
  end

  test "terms ride only when the spec has them; the signature block always does" do
    load_kit do |spec|
      p = MarketingKit::ProposalTemplate.new(spec).payload
      assert_nil p[:terms]
      refute p.dig(:acceptance, :terms)
      assert_equal "quotes@ridgeline.example", p.dig(:acceptance, :email)
    end
    terms = ->(d) { d["proposal"]["terms_of_service"] = { "intro" => ["These terms apply."], "items" => [["Payment", "Due on receipt."]] } }
    load_kit(edit: terms) do |spec|
      p = MarketingKit::ProposalTemplate.new(spec).payload
      assert_equal [["Payment", "Due on receipt."]], p.dig(:terms, :items)
      assert p.dig(:acceptance, :terms)
    end
  end

  test "the clients page takes the spec's logo image when it names one, else the names" do
    load_kit(edit: ->(d) { d["proposal"]["clients"] = %w[Acme Beta] }) do |spec|
      p = MarketingKit::ProposalTemplate.new(spec).payload
      assert_nil p.dig(:images, :clients)
      assert_equal %w[Acme Beta], p.dig(:clients, :names)
    end
    with_kit(edit: ->(d) { d["proposal"]["clients_logos"] = "clients.png" }) do |path|
      error = assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }
      assert_match(/proposal.clients_logos clients.png is not in/, error.message, "a missing logo image fails at load, not mid-render")
      File.write(File.join(File.dirname(path), "photos", "clients.png"), "png")
      spec = MarketingKit::Spec.load(path)
      assert_equal File.join(spec.photos_dir, "clients.png"), MarketingKit::ProposalTemplate.new(spec).payload.dig(:images, :clients)
    end
  end

  test "the cover and running header use the horizontal logo; each section has a label and a title" do
    load_kit do |spec|
      t = MarketingKit::ProposalTemplate.new(spec)
      assert_equal spec.logo_png(:horizontal, :light), t.payload.dig(:images, :logo)
      assert_equal ["About us", "Built to last"], t.payload.dig(:headings, :about), "the about title is the tagline"
      assert_equal %i[about details investment clients why terms acceptance], t.payload[:headings].keys
      assert_equal "RF Proposal Template", t.name
      assert_equal "RF-YYYY-000", t.payload.dig(:cover, :number)
    end
  end

  test "about and why carry the spec's one-line explanations; each photo's crop sits where the spec puts it" do
    edit = ->(d) { d["proposal"].merge!("about_line" => "Who we are.", "why_line" => "Why hire us.", "photo_focus" => { "cover" => 1, "about" => 0.1, "why" => 7 }) }
    load_kit(edit: edit) do |spec|
      p = MarketingKit::ProposalTemplate.new(spec).payload
      assert_equal ["About us", "Built to last", "Who we are."], p.dig(:headings, :about)
      assert_equal "Why hire us.", p.dig(:headings, :why).last
      assert_equal({ cover: 1.0, about: 0.1, why: 1.0 }, p[:focus], "a focus past the edge is held to it")
    end
    load_kit do |spec|
      p = MarketingKit::ProposalTemplate.new(spec).payload
      assert_equal 2, p.dig(:headings, :about).size, "no line, no third entry"
      assert_equal({ cover: 0.5, about: 0.5, why: 0.5 }, p[:focus])
    end
  end

  test "credential badges carry the spec's title, holder and per-tone logo; a missing logo file fails at load" do
    badges = [{ "title" => "Certified pipe", "holder" => "ASME-certified welders", "logo" => "asme.png", "logo_dark" => "asme-white.png" },
              { "title" => "Certified structural", "holder" => "AWS-certified welders" }]
    with_kit(edit: ->(d) { d["proposal"]["credential_badges"] = badges }) do |path|
      assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }
      %w[asme asme-white].each { |n| File.write(File.join(File.dirname(path), "photos", "#{n}.png"), "png") }
      spec = MarketingKit::Spec.load(path)
      light = MarketingKit::ProposalTemplate.new(spec).payload.dig(:cover, :badges)
      dark = MarketingKit::ProposalTemplate.new(spec, tone: :dark).payload.dig(:cover, :badges)
      assert_equal({ title: "Certified pipe", holder: "ASME-certified welders", logo: spec.photo_path("asme.png") }, light.first)
      assert_equal spec.photo_path("asme-white.png"), dark.first[:logo]
      assert_nil light.last[:logo], "a badge with no logo leads with the tick"
    end
    load_kit { |spec| assert_empty MarketingKit::ProposalTemplate.new(spec).payload.dig(:cover, :badges) }
  end

  test "the dark tone darkens the pages and uses the dark logo and the on-dark accent" do
    edit = ->(d) { d["proposal"]["clients_logos"] = "light.png"; d["proposal"]["clients_logos_dark"] = "dark.png" }
    with_kit(edit: edit) do |path|
      %w[light dark].each { |n| File.write(File.join(File.dirname(path), "photos", "#{n}.png"), "png") }
      spec = MarketingKit::Spec.load(path)
      light = MarketingKit::ProposalTemplate.new(spec).payload
      dark = MarketingKit::ProposalTemplate.new(spec, tone: :dark)
      p = dark.payload
      assert_equal "RF Proposal Template (Dark)", dark.name
      assert_equal spec.colour(:dark), p[:page]
      assert_nil light[:page], "the light tone has no page colour"
      assert_equal "#FFFFFF", p.dig(:colours, :primary), "titles are white on the dark page"
      assert_equal spec.colour(:accent_on_dark), p.dig(:colours, :accent)
      assert_equal spec.logo_png(:horizontal, :dark), p.dig(:images, :logo)
      assert_equal spec.photo_path("dark.png"), p.dig(:images, :clients)
      assert_equal spec.photo_path("light.png"), light.dig(:images, :clients)
      assert_raises(MarketingKit::Error) { MarketingKit::ProposalTemplate.new(spec, tone: :sepia) }
    end
  end
end

# [component] office.py draws the payload as a Word file: a page break before every section after the cover, the logo
# in the running header, the page number in the footer, and a cover with no header. Runs Python (the kit's shared venv).
class MarketingKitProposalDocxTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  test "the drawn proposal has one section per page, a running header and a numbered footer" do
    terms = ->(d) {
      d["proposal"]["terms_of_service"] = { "intro" => ["These terms apply."], "items" => [["Payment", "Due on receipt."]] }
      d["proposal"]["clients"] = %w[Acme Beta]
    }
    with_kit(edit: terms) do |path|
      dir = File.dirname(path)
      Dir.glob(File.join(dir, "{logos/png,photos}/*")).each { |f| File.binwrite(f, PNG) } # real images for Pillow
      spec = MarketingKit::Spec.load(path)
      out = File.join(dir, "proposal.docx")
      MarketingKit::Office.new(spec).write_proposal(out)

      xml = Zip::File.open(out) { |z| z.read("word/document.xml") }
      # cover | about | details | investment | clients | why | terms | acceptance
      assert_equal 7, xml.scan('w:type="page"').size, "a page break before each of the seven sections after the cover"
      ["PROPOSAL", "ABOUT US", "PROPOSAL DETAILS", "INVESTMENT", "CLIENTS", "WHY CHOOSE US", "TERMS OF SERVICE", "ACCEPTANCE"].each { |t| assert_includes xml, t }
      assert_includes xml, ">Total<"
      assert_includes xml, "w:titlePg", "the cover has its own (empty) header and footer"
      parts = Zip::File.open(out) { |z| z.entries.map(&:name).grep(%r{\Aword/(header|footer)\d*\.xml\z}).map { |n| z.read(n) } }
      assert(parts.any? { |h| h.include?("<w:hdr") && h.include?("r:embed") }, "the running header carries the logo")
      assert(parts.any? { |h| h.include?("<w:ftr") && h.include?("PAGE") }, "the footer numbers the pages")
    end
  end

  test "the dark proposal sets the page colour and floats the cover photo behind the title" do
    with_kit do |path|
      dir = File.dirname(path)
      Dir.glob(File.join(dir, "{logos/png,photos}/*")).each { |f| File.binwrite(f, PNG) }
      spec = MarketingKit::Spec.load(path)
      out = File.join(dir, "dark.docx")
      MarketingKit::Office.new(spec).write_proposal(out, tone: :dark)
      xml = Zip::File.open(out) { |z| z.read("word/document.xml") }
      assert_includes xml, %(<w:background w:color="#{spec.colour(:dark).delete('#')}"/>)
      assert_equal 3, xml.scan('behindDoc="1"').size, "the cover, about and why photos sit behind their words"
      assert_includes xml, "<wp:wrapNone/>"
    end
  end
end

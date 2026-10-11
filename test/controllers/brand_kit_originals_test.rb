# frozen_string_literal: true

require "test_helper"

# [component] Kit originals through the routes (task brand-kit-record): upload one or more files to a brand's kit,
# list them on the brand page with name, type, size and date, preview pictures inline, serve every file from behind
# the admin wall (an SVG sandboxed), download and delete, and refuse what is not artwork by drawing the brand page
# again as a 422 with the reason in the card.
class BrandKitOriginalsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def svg = fixture_file_upload("brand_kit/original.svg", "image/svg+xml")
  def png = fixture_file_upload("magic-banner.png", "image/png")
  def kit(brand = "studio") = BrandKit.find_by(brand:)

  test "an empty card says what originals are and that none are uploaded" do
    log_in_as(@admin)
    get logo_brand_path("studio", type: "icon")
    assert_select "[data-test='kit-originals']" do
      assert_select "p", "The originals the logos were derived from."
      assert_select "[data-test='kit-originals-empty']", "No originals uploaded yet."
      assert_select "form[data-test='kit-original-form'][action='#{brand_kit_originals_path('studio')}'][enctype='multipart/form-data']"
      assert_select "input[type=file][name='originals[]'][multiple]"
      assert_select "input[type=hidden][name=type][value=icon]"
    end
  end

  test "uploading an SVG and a PNG creates the kit, lists both, and previews them from behind the wall" do
    log_in_as(@admin)
    post brand_kit_originals_path("studio"), params: { originals: [svg, png], type: "stacked" }
    assert_redirected_to logo_brand_path("studio", type: "stacked", anchor: "kit-originals")
    assert_equal "Uploaded 2 originals: original.svg and magic-banner.png.", flash[:notice]
    assert_equal %w[original.svg magic-banner.png], kit.originals.map { |o| o.filename.to_s }
    assert_equal @admin.email, kit.updated_by

    follow_redirect!
    items = css_select("[data-test='kit-original']")
    assert_equal %w[SVG PNG], items.map { |item| item["data-type"] }
    assert_equal %w[original.svg magic-banner.png], items.map { |item| item.at_css("[data-test='kit-original-name']").text.strip }
    date = kit.originals.first.created_at.strftime("%b %-d, %Y")
    assert_equal ["SVG · 112 Bytes · uploaded #{date}", "PNG · 70 Bytes · uploaded #{date}"],
                 items.map { |item| item.at_css("[data-test='kit-original-meta']").text.squish }
    previews = css_select("img[data-test='kit-original-preview']").map { |img| img["src"] }
    assert_equal kit.originals.map { |o| brand_kit_original_path("studio", o) }, previews

    get previews.first
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal "inline", response.headers["Content-Disposition"][/\A\w+/]
    assert_includes response.headers["Content-Security-Policy"], "sandbox"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'none'"
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal File.binread(file_fixture("brand_kit/original.svg")), response.body
  end

  test "a download is an attachment, and a PDF or ZIP is never shown inline" do
    record = BrandKit.for("industries")
    record.add_originals([png], by: "alex@test.com")
    record.originals.attach(io: StringIO.new("%PDF-1.4\n%%EOF\n"), filename: "kit.pdf", content_type: "application/pdf", identify: false)
    record.save!
    log_in_as(@admin)
    get logo_brand_path("industries")
    pdf = css_select("[data-test='kit-original'][data-type='PDF']").first
    assert_empty pdf.css("img"), "a PDF has no preview"
    get pdf.at_css("[data-test='kit-original-download']")["href"]
    assert_match(/\Aattachment; filename="kit.pdf"/, response.headers["Content-Disposition"])
    get brand_kit_original_path("industries", record.originals.find_by(blob: ActiveStorage::Blob.find_by(filename: "kit.pdf")))
    assert_equal "attachment", response.headers["Content-Disposition"][/\A\w+/], "only pictures are served inline"
  end

  # Task logo-gallery-polish-pass, item 5: Delete sits beside Download, so it asks first, with no script: the first
  # step is a closed disclosure, and the delete button inside it names the file.
  test "a delete takes two steps: a closed disclosure naming the file holds the only delete button" do
    BrandKit.for("studio").add_originals([svg], by: "alex@test.com")
    log_in_as(@admin)
    get logo_brand_path("studio", type: "stacked")
    item = css_select("[data-test='kit-original']").first
    disclosure = item.at_css("details[data-test='kit-original-delete-disclosure']")
    assert disclosure, "the delete is behind a disclosure"
    refute disclosure.key?("open"), "closed until asked"
    assert_equal "Delete original.svg Cancel deleting original.svg", disclosure.at_css("summary[data-test='kit-original-delete']").text.squish
    assert_equal "Delete original.svg from the kit?", disclosure.at_css("[data-test='kit-original-delete-ask'] p").text.squish
    forms = item.css("form").select { |form| form.at_css("input[name=_method][value=delete]") }
    assert_equal 1, forms.size, "one delete form, and it is inside the disclosure"
    assert_equal disclosure, forms.first.ancestors("details").first
    assert_equal "Delete original.svg", forms.first.at_css("[data-test='kit-original-delete-confirm']").text.squish
    assert_equal brand_kit_original_path("studio", kit.originals.first), forms.first["action"]
    assert_equal "stacked", forms.first.at_css("input[name=type]")["value"]
    assert_empty item.css("[onsubmit], [onclick], script")
  end

  test "deleting an original removes it and returns to the card" do
    record = BrandKit.for("studio")
    record.add_originals([svg, png], by: "alex@test.com")
    log_in_as(@admin)
    delete brand_kit_original_path("studio", record.originals.first), params: { type: "navbar" }
    assert_redirected_to logo_brand_path("studio", anchor: "kit-originals")
    assert_equal "Removed original.svg.", flash[:notice]
    assert_equal %w[magic-banner.png], kit.originals.map { |o| o.filename.to_s }
  end

  # Task logo-gallery-polish-pass, item 6: a refusal draws the brand page again, on the tab and in the context the
  # form carried, with the reason in the Kit originals card and the other cards intact.
  test "an upload that is not artwork draws the brand page again as a 422, with the reason in the originals card, and nothing is kept" do
    BrandKit.for("studio").save_choice(:navbar, ActionController::Parameters.new(rule: "3", text: "first"), by: "alex@test.com")
    log_in_as(@admin)
    post brand_kit_originals_path("studio"), params: { originals: [png, fixture_file_upload("brand_kit/not-a-picture.png", "image/png")], type: "stacked", context: "watermark" }
    assert_response :unprocessable_content
    assert_equal "text/html", response.media_type
    assert_select "[data-test='kit-originals'] [data-test='kit-original-refused'][role=alert]",
                  "Not uploaded: not-a-picture.png is not an SVG, PNG, JPEG, PDF or ZIP (read from its contents, not its name)"
    assert_select "[data-test='kit-originals-empty']", "No originals uploaded yet."
    assert_select "[data-test='logo-type'][data-type='stacked']", 1
    assert_select "[data-test='logo-example'][data-tones='watermark']", 3
    assert_select "[data-test='kit-choice'][data-type='stacked']", 1
    assert_select "[data-test='kit-card'] [data-test='kit-pick'][data-type='navbar'][data-saved='true']", 1
    assert_select "[data-test='brand-colours']", 1
    assert_select "form[data-test='kit-original-form'] input[type=hidden][name=type][value=stacked]", 1
    assert_select "form[data-test='kit-original-form'] input[type=hidden][name=context][value=watermark]", 1

    { [""] => "choose at least one file to upload", ["just a string"] => "an original must be an uploaded file" }.each do |files, reason|
      post brand_kit_originals_path("studio"), params: { originals: files }
      assert_response :unprocessable_content
      assert_select "[data-test='kit-original-refused']", "Not uploaded: #{reason}"
      assert_select "[data-test='logo-type'][data-type='navbar']", 1
    end
    assert_equal 0, ActiveStorage::Attachment.where(record_type: "BrandKit").count

    get logo_brand_path("studio")
    assert_select "[data-test='kit-original-refused']", 0, "only the refused upload's page says so"
  end

  test "a refused upload to a brand with no kit yet creates none" do
    log_in_as(@admin)
    assert_no_difference -> { BrandKit.count } do
      post brand_kit_originals_path("turf"), params: { originals: [fixture_file_upload("brand_kit/not-a-picture.png", "image/png")] }
    end
    assert_response :unprocessable_content
    assert_select "[data-test='kit-status']", "Kit: not saved yet"
  end

  test "an original of another brand, or of none, is a 404" do
    record = BrandKit.for("studio")
    record.add_originals([png], by: "alex@test.com")
    log_in_as(@admin)
    get brand_kit_original_path("industries", record.originals.first)
    assert_response :not_found
    get brand_kit_original_path("studio", 0)
    assert_response :not_found
    delete brand_kit_original_path("industries", record.originals.first)
    assert_response :not_found
    assert_equal 1, record.originals.count
  end

  test "only admins can see, upload or delete originals" do
    record = BrandKit.for("studio")
    record.add_originals([png], by: "alex@test.com")
    original = record.originals.first
    requests = {
      see: -> { get brand_kit_original_path("studio", original) },
      upload: -> { post brand_kit_originals_path("studio"), params: { originals: [svg] } },
      delete: -> { delete brand_kit_original_path("studio", original) }
    }
    requests.each do |name, request|
      request.call
      assert_response :redirect, "#{name} as a visitor"
    end
    log_in_as(@viewer)
    requests.each do |name, request|
      request.call
      assert_redirected_to root_path, "#{name} as a viewer"
    end
    assert_equal %w[magic-banner.png], record.reload.originals.map { |o| o.filename.to_s }
  end
end

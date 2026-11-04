# frozen_string_literal: true

require "test_helper"

# [component] /marketing-kit: the public brand page.
class MarketingKitPageTest < ActionDispatch::IntegrationTest
  test "a signed-out visitor sees the logos, colours and typefaces" do
    get marketing_kit_path
    assert_response :success

    assert_select "h1", text: "Marketing Kit", count: 1
    kit = Logos::BrandKit.new("studio")
    kit.palette.each do |swatch|
      assert_select "[data-test='kit-colours'] code", text: swatch.hex
    end
    kit.typefaces.each do |face|
      assert_select "[data-test='kit-type'] p", text: /#{Regexp.escape(face.name)}/
    end
  end

  test "every logo download is a static file a visitor can fetch" do
    get marketing_kit_path

    links = css_select("[data-test='kit-logos'] a[download]").map { |a| a["href"] }
    assert_equal 6, links.size
    links.each do |href|
      assert_match %r{\A/brand/[a-z]+-(light|dark)\.png\z}, href
      assert File.file?(Rails.public_path.join(href.delete_prefix("/"))), "#{href} is not in public/"
    end
  end

  test "the light icon tile escapes the dark-page icon swap, so it keeps its tone" do
    get marketing_kit_path

    assert_select "[data-test='kit-logos'] img", 6
    assert_select "[data-test='kit-logos'] img[src='/brand/icon-light.svg']", 0
    assert_select "[data-test='kit-logos'] img[src=?]", "/brand/icon-light.svg?kit", 1
  end

  test "logo links read Download Light and Download Dark" do

    get marketing_kit_path


    texts = css_select("[data-test='kit-logos'] a[download]").map { |a| a.text.strip }.uniq

    assert_equal [ "Download Light", "Download Dark" ], texts

  end


  test "a click on a colour copies its hex" do

    get marketing_kit_path


    Logos::BrandKit.new("studio").palette.each do |swatch|

      assert_select "[data-test='kit-colours'] button[data-copy-hex='#{swatch.hex}']"

    end

  end


  test "the footer shows and links the page for a signed-in viewer too" do
    log_in_as users(:viewer)
    get marketing_kit_path
    assert_response :success

    assert_select "footer[data-site-footer] nav[aria-label='Company'] a[href='#{marketing_kit_path}']", text: "Marketing Kit"
  end
end

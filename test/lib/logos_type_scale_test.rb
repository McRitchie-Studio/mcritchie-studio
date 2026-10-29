# frozen_string_literal: true

# [unit] Logos::TypeScale (task brand-kit-type-scale): every text role as a multiple of one base (title 6x, heading
# 3x, subhead 1.5x, body 1x, fine print 3/4x), on a 24 px social base and a 16 px web base, set in the brand's faces.

require "minitest/autorun"
require_relative "../../lib/logos/type_scale"

class LogosTypeScaleTest < Minitest::Test
  TypeScale = Logos::TypeScale

  def scale(brand) = TypeScale.new(Logos::BrandKit.new(brand))
  def sizes(brand, surface) = scale(brand).surfaces.find { |each| each.key == surface }.sizes.map(&:px)

  def test_the_reels_scale_on_a_1080_social_post
    assert_equal [144, 72, 36, 24, 18], sizes("studio", "social")
  end

  def test_the_same_multiples_on_a_16px_web_base
    assert_equal [96, 48, 24, 16, 12], sizes("studio", "web")
  end

  def test_roles_run_largest_first_and_name_their_multiples
    assert_equal %w[title heading subhead body fine-print], scale("turf").roles.map(&:key)
    assert_equal %w[6x 3x 1.5x 1x 3/4x], scale("turf").roles.map(&:multiple_label)
  end

  def test_every_brand_sets_every_role_in_a_face_it_has
    Logos::BrandKit.all.each do |kit|
      fonted = kit.typefaces.reject(&:traced?)
      TypeScale.new(kit).roles.each { |role| assert_includes fonted, role.typeface, "#{kit.brand} #{role.key}" }
    end
  end

  def test_display_face_for_title_and_heading_text_face_for_the_rest
    roles = scale("studio").roles.to_h { |role| [role.key, role.typeface.name] }
    assert_equal({ "title" => "Montserrat ExtraBold", "heading" => "Montserrat ExtraBold", "subhead" => "Montserrat Light",
                   "body" => "Montserrat Light", "fine-print" => "Montserrat Light" }, roles)
  end

  # Welding's display level is traced lettering, which has no font, so every role falls to its Montserrat level.
  def test_traced_display_falls_back_to_a_font
    assert_equal ["Montserrat Medium"], scale("welding").roles.map { |role| role.typeface.name }.uniq
  end

  def test_css_tokens_name_brand_surface_and_role
    css = scale("welding_v2").css
    assert_includes css, "  --welding-v2-social-text-title: 144px;\n"
    assert_includes css, "  --welding-v2-text-fine-print: 12px;\n"
    assert_equal 10, css.scan(/^  --/).size
  end
end

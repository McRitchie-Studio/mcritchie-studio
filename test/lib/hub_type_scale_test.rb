# frozen_string_literal: true

require "test_helper"

# [unit] Task hub-adopts-type-scale: every Tailwind font size the hub uses lands
# on one of the engine's five roles (app/assets/tailwind/type_scale.css), at the
# multiples Studio::TypeScale::ROLES names; no view sets a pixel size of its own;
# and the four Studio.type_* settings are the studio kit's.
class HubTypeScaleTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/type_scale.css")
  # Alex McRitchie's go of 2026-10-29: the old sizes sorted onto the five steps.
  EXPECTED = {
    "3xs" => 0.75, "2xs" => 0.75, "xs" => 0.75,
    "sm" => 1, "base" => 1,
    "lg" => 1.5, "xl" => 1.5, "2xl" => 1.5,
    "3xl" => 3, "4xl" => 3,
    "5xl" => 6, "6xl" => 6, "7xl" => 6, "8xl" => 6, "9xl" => 6
  }.freeze
  SIZE_CLASS = /(?<![\w-])text-(3xs|2xs|xs|sm|base|lg|[2-9]?xl)(?![\w-])/

  def mapped
    CSS.read.scan(/--text-([0-9a-z]+): calc\(var\(--type-base, 16px\) \* ([\d.]+)\);/).to_h { |size, n| [size, n.to_f] }
  end

  def sources = Dir[Rails.root.join("app/{views,components,helpers,javascript}/**/*.{erb,rb,js}")]

  test "every Tailwind size maps to its step" do
    assert_equal EXPECTED.transform_values(&:to_f), mapped
  end

  test "every multiple is one of the engine's roles" do
    roles = Studio::TypeScale::ROLES.map { |_, multiple, _| multiple.to_f }
    assert_empty mapped.values.uniq - roles
    assert_equal roles.sort, mapped.values.uniq.sort, "each role is reached by some size"
  end

  test "every size class in the app is a mapped one" do
    used = sources.flat_map { |path| File.read(path).scan(SIZE_CLASS).flatten }.uniq
    assert_empty used - mapped.keys
  end

  test "no source sets an arbitrary font size" do
    offenders = sources.select { |path| File.read(path).match?(/text-\[[\d.]+(px|rem|em)\]/) }
    assert_empty offenders.map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
  end

  test "the map is imported after the engine layer, so it wins" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_operator css.index("@import '../builds/tailwind/studio_engine'"), :<, css.index("@import './type_scale.css'")
  end

  test "the Studio.type_* settings are the studio kit's" do
    kit = JSON.parse(Rails.root.join("public/brand/kit.json").read).fetch("type_scale")
    assert_equal kit, { "type_base" => Studio.type_base, "type_dense_base" => Studio.type_dense_base,
                        "type_display_weight" => Studio.type_display_weight, "type_text_weight" => Studio.type_text_weight }
  end
end

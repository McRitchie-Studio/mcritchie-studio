# frozen_string_literal: true

require "minitest/autorun"
require "bundler"

# [unit] The hub's Gemfile keeps the component gallery's load order
# (task hub-shows-lookbook-gallery-live).
#
# studio-engine never requires lookbook; the hub opts in by bundling it. Two
# rules hold for that to work on the live hub:
#
#   1. lookbook is listed AFTER studio-engine. Bundler.require loads gems in
#      Gemfile order, and ViewComponent (pulled in by the engine) must decide
#      its preview routes before Lookbook turns previews on. Listed first, the
#      engine warns at boot (Studio::ComponentGallery.load_order_ok?).
#   2. lookbook is in the default group and auto-required, so production
#      loads it. In a development group, or with `require: false`, production
#      has no Lookbook::Engine and Studio.lookbook_in_production draws nothing.
#
# Parsed with Bundler's own DSL, so a comment or a string mentioning lookbook
# cannot satisfy it. Standalone: bundle exec ruby -Itest test/lib/gemfile_lookbook_order_test.rb
class GemfileLookbookOrderTest < Minitest::Test
  GEMFILE = File.expand_path("../../Gemfile", __dir__)

  def dependencies
    @dependencies ||= begin
      dsl = Bundler::Dsl.new
      dsl.eval_gemfile(GEMFILE)
      dsl.dependencies
    end
  end

  def index_of(name)
    dependencies.index { |dep| dep.name == name }
  end

  def lookbook = dependencies.find { |dep| dep.name == "lookbook" }

  def test_lookbook_is_listed_after_studio_engine
    engine = index_of("studio-engine")
    gallery = index_of("lookbook")

    refute_nil engine, "the Gemfile does not list studio-engine"
    refute_nil gallery, "the Gemfile does not list lookbook, so the live hub draws no gallery"
    assert_operator gallery, :>, engine, "lookbook is listed before studio-engine"
  end

  def test_lookbook_is_bundled_for_production_and_required
    assert_equal [ :default ], lookbook.groups, "lookbook is in a group production does not load"
    refute_equal [ false ], Array(lookbook.autorequire), "lookbook is require: false, so production never loads it"
  end

  # The control: the same reading of the Gemfile sees a gem that IS confined to
  # a group, so the default-group assertion above can fail.
  def test_control_the_reader_sees_groups
    dotenv = dependencies.find { |dep| dep.name == "dotenv-rails" }

    refute_nil dotenv
    refute_includes dotenv.groups, :default
  end
end

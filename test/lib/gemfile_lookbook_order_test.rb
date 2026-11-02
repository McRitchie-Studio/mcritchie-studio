# frozen_string_literal: true

require "minitest/autorun"
require "bundler"

# [unit] The hub's Gemfile keeps the component gallery's load order; the hub opts in by bundling
# lookbook.
#   1. lookbook is listed AFTER studio-engine: Bundler.require loads in Gemfile order and
#      ViewComponent must decide its preview routes first, or the engine warns
#      (Studio::ComponentGallery.load_order_ok?).
#   2. lookbook is in the default group and auto-required, or production has no
#      Lookbook::Engine and Studio.lookbook_in_production draws nothing.
# History: task hub-shows-lookbook-gallery-live.
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

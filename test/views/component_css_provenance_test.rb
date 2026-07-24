require "test_helper"

# Guards the studio-engine component-CSS adoption (task: adopt-engine-component-css).
#
# The change this locks in: MS sources its .btn* / .card / .badge / .input-field /
# .empty-state / .json-debug / .label-upper utilities from the studio-engine build
# import instead of a local fork. The compiled tailwind.css was byte-identical before
# and after, so there is no visual behavior to assert — the real regression risk is
# STRUCTURAL: a future edit silently re-forking a class (which then drifts from the
# engine) or dropping the import (which strips the components entirely). This guards
# both ends of that seam: the app imports the engine build, the app does not redefine
# the shared utilities, and the engine actually ships them.
class ComponentCssProvenanceTest < ActiveSupport::TestCase
  APP_CSS    = Rails.root.join("app/assets/tailwind/application.css")
  ENGINE_CSS = Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css")

  # The shared utilities MS delegated to the engine. .btn-* are covered by the
  # `btn` prefix check below; these are the exact class names MS must not re-fork.
  SHARED_UTILITIES = %w[
    btn btn-primary btn-secondary btn-outline btn-danger btn-warning btn-success
    btn-google btn-neutral btn-sm btn-lg
    card card-hover badge input-field empty-state json-debug label-upper
  ].freeze

  test "[component] application.css imports the studio-engine component build" do
    assert_match %r{@import\s+['"]\.\./builds/tailwind/studio_engine['"]}, APP_CSS.read,
      "application.css must @import ../builds/tailwind/studio_engine so the shared " \
      "component utilities come from studio-engine, not a local fork"
  end

  test "[component] application.css does not re-fork the shared engine utilities" do
    css = APP_CSS.read
    SHARED_UTILITIES.each do |util|
      assert_no_match(/@utility\s+#{Regexp.escape(util)}\s*\{/, css,
        "application.css re-declares @utility #{util}; it must be inherited from the " \
        "engine import instead (a local copy silently drifts from the canonical version)")
    end
  end

  test "[component] the studio-engine build actually ships those utilities" do
    engine_css = ENGINE_CSS.read
    # Sample the load-bearing ones — if these are present the import is a real source.
    %w[btn btn-primary card card-hover badge input-field empty-state].each do |util|
      assert_match(/@utility\s+#{Regexp.escape(util)}\s*\{/, engine_css,
        "studio-engine engine.css must define @utility #{util} for the app to inherit it")
    end
  end
end

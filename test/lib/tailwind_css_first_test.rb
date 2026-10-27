require "test_helper"

# The hub builds Tailwind CSS-first through studio-engine's host.css
# (studio-engine README "Tailwind", CHANGELOG 0.114.2; task
# hub-adopts-css-first-tailwind). One import brings the theme, the engine's
# @source scan and the motion layer, so the hub carries no @config, no JS
# preset, no content glob over the gem and no motion import of its own.
#
# Each of those is SILENT when it comes back: an @config still builds (and its
# safelist does nothing under Tailwind 4, which is how the hub's 231-class
# primary safelist sat inert in production), and a second motion import only
# duplicates the layer. So the shape is held here, and the build is read.
class TailwindCssFirstTest < ActiveSupport::TestCase
  ROOT = Rails.root
  MOTION_CSS = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir)
               .join("app/assets/tailwind/studio_engine/engine-motion.css")

  def application_css
    ROOT.join("app/assets/tailwind/application.css").read.gsub(%r{/\*.*?\*/}m, " ")
  end

  def compiled
    Rails.application.assets.load_path.find("tailwind.css").compiled_content
  end

  test "[unit] application.css imports the engine entry and carries no @config or motion import" do
    css = application_css
    assert_match %r{^@import ['"]tailwindcss['"];}, css
    assert_match %r{^@import ['"]\.\./builds/tailwind/studio_engine['"];}, css
    refute_match(/@config\b/, css, "the theme comes from the engine's theme.css; @config re-reads the deprecated JS preset")
    refute_match(/studio_engine_motion|engine-motion/, css, "host.css imports the motion layer; a second import duplicates it")
  end

  test "[unit] the JS preset, its host config and the motion rake task are gone" do
    refute ROOT.join("config/tailwind.config.js").exist?, "config/tailwind.config.js read the deprecated preset"
    refute ROOT.join("lib/tasks/tailwindcss_engine_motion.rake").exist?, "host.css imports engine-motion.css itself"
  end

  # The trap: `@source not "../../../vendor/bundle"` once dropped every engine
  # class in CI, where the gem itself lives under vendor/bundle.
  test "[unit] the only vendor/bundle exclusion is its Markdown" do
    # Read raw, by line: the glob's `/**/` looks like a comment to a naive strip.
    raw = ROOT.join("app/assets/tailwind/application.css").read
    exclusions = raw.scan(/^\s*@source\s+not\s+(["'][^"']+["'])/).flatten
    assert_equal [ %("../../../vendor/bundle/**/*.md") ], exclusions
  end

  test "[integration] the build carries the theme, the components and the motion layer once" do
    css = compiled
    # One class from each column of the engine README's table: theme token,
    # component utility, motion primitive.
    [ ".text-heading", ".btn-primary", ".spinner" ].each do |sel|
      assert css.include?("#{sel}{"), "#{sel} is missing from the build"
    end

    keyframe = "@keyframes modal-card-in"
    assert_equal MOTION_CSS.read.scan(/#{keyframe}\b/).size, css.scan(/#{keyframe}\b/).size,
                 "the motion layer compiled a different number of times than engine-motion.css defines it"
  end
end

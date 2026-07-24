require "test_helper"

# Guards the heartbeat/activities style de-inline (task: de-inline-heartbeat-styles).
#
# The heartbeat + activities <style> blocks were 100% static yet re-serialized on
# every HTML response. They now live in app/assets/tailwind/heartbeat.css, imported
# by the tailwind entry so they compile once into tailwind.css. This locks that in:
# the partials must stay inline-free, the stylesheet must exist and be imported, and
# the load-bearing rules must be present — so a future edit can't silently re-inline
# the block or drop the import.
class HeartbeatStylesDeinlinedTest < ActiveSupport::TestCase
  APP_CSS       = Rails.root.join("app/assets/tailwind/application.css")
  HEARTBEAT_CSS = Rails.root.join("app/assets/tailwind/heartbeat.css")
  PARTIALS = [
    Rails.root.join("app/views/heartbeat/_styles.html.erb"),
    Rails.root.join("app/views/agents/_activities_styles.html.erb"),
  ].freeze

  test "[component] the de-inlined heartbeat partials no longer emit an inline <style>" do
    PARTIALS.each do |partial|
      assert_no_match(/<style\b/, partial.read,
        "#{partial.basename} must not re-inline a <style> block — the rules live in heartbeat.css now")
    end
  end

  test "[component] the tailwind entry imports the de-inlined heartbeat stylesheet" do
    assert_match %r{@import\s+['"]\./heartbeat\.css['"]}, APP_CSS.read,
      "application.css must @import ./heartbeat.css so the rules compile into tailwind.css"
  end

  test "[component] heartbeat.css carries the load-bearing rules and keyframes" do
    css = HEARTBEAT_CSS.read
    assert_match(/#alex-heartbeat\b/, css, "heartbeat.css must scope its rules to #alex-heartbeat")
    %w[aa-flash aa-spin hb-spin aa-count-pulse].each do |kf|
      assert_match(/@keyframes\s+#{Regexp.escape(kf)}\b/, css,
        "heartbeat.css must define @keyframes #{kf} (carried over from the inline block)")
    end
    # It is a plain stylesheet now — no ERB, no <style> wrapper.
    assert_no_match(/<style\b|<%/, css, "heartbeat.css must be plain static CSS (no <style> tag, no ERB)")
  end
end

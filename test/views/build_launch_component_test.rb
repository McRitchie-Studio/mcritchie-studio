require "test_helper"
require_relative "../support/client_cto_fixtures"

# [component] Build My App's hand-off to the CTO (task build-launch-handoff):
# the launch panel (build/_launch) that replaces the /build shell, its three
# steps in order and in the app's colours, the portrait carrying the shell's
# view-transition name; and the app chat's stage pills (agent_chats/_devops_card),
# whose live stage glows in the app's own palette, with the studio primary as
# the fallback (app/assets/tailwind/build_launch.css).
class BuildLaunchComponentTest < ActionView::TestCase
  include ClientCtoFixtures
  helper ClientCtoHelper

  CSS = Rails.root.join("app/assets/tailwind/build_launch.css")

  def launch_locals(app = client_app!)
    { app_cto: app.client_cto, cto: AppOwnership.cto_for_app(app.slug), href: "/applications/#{app.slug}/chat" }
  end

  test "[component] the launch panel shows the CTO's portrait, the app's name and the three steps, the first under way" do
    render partial: "build/launch", locals: launch_locals

    panel = css_select("build-launch#build-launch[data-test='build-launch']").sole
    assert_equal "/applications/pawsome/chat", panel["data-href"], "where the panel hands over"
    assert_select "[data-test='build-launch-portrait'][style*='view-transition-name: agent-portrait'] [data-test='client-cto-portrait'][src*='cto_portraits/harbor']"
    assert_select "[data-test='build-launch-caption'][style*='view-transition-name: agent-caption']", text: /Nova\s+· CTO of Pawsome/
    assert_select "[data-test='build-launch-app']", text: "Pawsome"
    assert_equal [ "Building Brand Sheet", "Hatching CTO", "Setting Up Domain" ],
                 css_select("[data-test='build-launch-step']").map { |li| li.text.squish }
    assert_equal %w[active pending pending], css_select("[data-test='build-launch-step']").map { |li| li["data-state"] }
    assert_equal %w[on off off], css_select("[data-test='build-launch-step'].cta-glow").map { |li| li["data-glow"] },
                 "the shared CTA glow, lit on the active step only"
    assert_select "[data-test='build-launch-portrait'].cta-glow"
    assert_select "[data-build-launch-status][role='status']"
    assert_select "a[data-test='build-launch-skip'][href='/applications/pawsome/chat']:not([data-turbo-action])", text: "Go to Nova now"
  end

  test "[component] the launch panel wears the app's palette in both modes" do
    render partial: "build/launch", locals: launch_locals

    panel = css_select("[data-test='build-launch']").sole
    assert_includes panel["style"], "--cto-primary-light: 79 70 229;"
    assert_includes panel["style"], "--cto-accent-dark: 251 191 36;"
    assert_includes panel["class"], "build-launch"
    assert_includes panel["class"], "dark:[--cto-primary:var(--cto-primary-dark)]"
  end

  test "[component] the live stage pill glows, a done one carries a check, a future one stays muted" do
    app = client_app!
    stages = AppDevopsStages.from("assembled").map { |stage| stage.live? ? stage.dup.tap { |s| s.count = 1 } : stage }
    board = AppDevopsStages::Board.new(stages: stages, total: 1,
                                       items: [ AppDevopsStages::Item.new(title: "Build Launch App", lane: "Releasing") ])
    render partial: "agent_chats/devops_card",
           locals: { app: app, board: board, client: true, palette_style: client_cto_palette_style(app.client_cto) }

    assert_select "[data-test='cto-chat-head'][style*='--cto-primary-light: 79 70 229;']"
    assert_select "ol.devops-stages[data-test='devops-stages']"
    assert_select "[data-test='devops-stage'][data-stage='building'][data-state='done']:not(.cta-glow) .devops-stage-pill.devops-stage-done .devops-stage-mark", text: "✓"
    assert_select "[data-test='devops-stage'][data-stage='releasing'][data-state='live'].cta-glow[aria-current='step'] .devops-stage-pill.devops-stage-live .devops-stage-dot", 2
    assert_select "[data-test='devops-stage'][data-stage='deploying'][data-state='pending']:not(.cta-glow) .devops-stage-pill.text-muted"
    assert_select "[data-test='devops-stage'].cta-glow", 1, "only the live stage glows"
    assert_select "[data-test='devops-stage'] .bg-primary", 0, "no studio-primary utility: the colour is the app's"
  end

  test "[component] the glow is the shared cta-glow in the CTO palette's colours, falling back to the studio primary" do
    css = CSS.read
    assert_match(/--launch-tint:\s*rgb\(var\(--cto-primary\)\);/, css)
    assert_match(/--launch-glow:\s*var\(--launch-tint,\s*var\(--color-primary\)\);/, css, "no CTO palette: the studio primary")
    shared = css[/\.build-launch \.cta-glow,\s*\.devops-stages \.cta-glow\s*\{[^}]*\}/m].to_s
    assert_includes shared, "--glow-a: var(--launch-glow);", "the shared CTA glow's stops are the CTO palette's"
    assert_includes shared, "--glow-b: var(--launch-glow-accent);"
    refute_match(/@keyframes [a-z-]*glow/, css, "no second glow primitive: cta-glow draws it")
    assert_includes Rails.root.join("app/assets/tailwind/cta_glow.css").read, ".cta-glow::before"
    assert_match(/\.build-launch-step\[data-state="active"\] \.build-launch-ring\s*\{[^}]*animation:/m, css)
    reduced = css[/@media \(prefers-reduced-motion: reduce\)\s*\{.*\z/m].to_s
    assert_match(/\.build-launch-step\[data-state="active"\] \.build-launch-ring\s*\{\s*animation:\s*none;/m, reduced, "the ring holds still")
    assert_includes Rails.root.join("app/assets/tailwind/application.css").read, "@import './build_launch.css';"
  end
end

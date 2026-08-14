# frozen_string_literal: true

require "test_helper"

# [component] The engine's first-name step, rendered in THIS app.
#
# The partial itself belongs to studio-engine and is covered by the gem's own
# suite. What is this app's to get wrong — and what this file covers — is the
# seam between them:
#
#   1. The partial RESOLVES from the gem here at all. It is referenced by a
#      string path inside a <template x-if>, so a gem that stopped shipping it
#      (or a path typo) raises only when a signed-in user without a first name
#      loads a page — which no other test in this app would notice.
#   2. Its default endpoints match the routes THIS app draws. The partial
#      defaults to /onboarding/first_name; this app opts into exactly those. If
#      either side moved, the modal would post into a 404 with every other test
#      still green.
class OnboardingFirstNameComponentTest < ActionView::TestCase
  def render_step(**locals)
    render partial: "studio/modals/onboarding/first_name", locals: locals
  end

  test "[component] the shared step renders from the gem in this app" do
    render_step

    assert_select "input#onboarding-first-name"
    assert_includes rendered, "Save and continue"
  end

  test "[component] its default endpoints are the routes this app draws" do
    render_step

    assert_includes rendered, onboarding_first_name_path
    assert_includes rendered, onboarding_skip_first_name_path
  end

  test "[component] the x-data carries no double quote" do
    # A double quote inside the double-quoted x-data attribute closes it early
    # and the component mounts as a SILENT no-op — the markup still renders, so
    # every string assertion above would still pass while the modal is dead in a
    # browser. Carried app-side too because this app can pass locals that end up
    # INSIDE that attribute.
    render_step(subtext: "Just your first name — we use it to address you in emails.")
    x_data = Nokogiri::HTML::DocumentFragment.parse(rendered).at_css("[x-data]")["x-data"]

    assert_not_includes x_data, '"'
  end

  test "[component] it renders a single root so Alpine can mount it" do
    # The modal host clones this out of a <template x-if>; Alpine silently mounts
    # NOTHING when the template's content has more than one root element.
    render_step
    roots = Nokogiri::HTML::DocumentFragment.parse(rendered)
                                            .children.reject { |n| n.text? && n.text.strip.empty? }

    assert_equal 1, roots.size, "got: #{roots.map(&:name).inspect}"
  end
end

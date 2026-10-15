# frozen_string_literal: true

require "test_helper"

# [integration] /docs/<path> renders a doc whose Markdown carries a javascript:
# link without a clickable href to it. The doc lives in a throwaway root swapped
# in for DocsController::DOCS_ROOT, so nothing is written into docs/agents.
class DocsSafeLinksTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex))
    @root = Pathname.new(Dir.mktmpdir("docs-safe-links"))
    File.write(@root.join("probe.md"), <<~MD)
      # Probe

      A [bad link](javascript:alert(1)), a [sibling](building-sop.md) and [out](https://example.com).
    MD
    @original_root = DocsController::DOCS_ROOT
    swap_root(@root)
  end

  teardown do
    swap_root(@original_root)
    FileUtils.rm_rf(@root)
  end

  test "a javascript: link in a doc renders as text" do
    get doc_path("probe")
    assert_response :success

    hrefs = css_select("a").map { |a| a["href"] }
    assert hrefs.none? { |href| href.to_s.strip.downcase.start_with?("javascript:") }, hrefs.inspect
    assert_includes hrefs, "building-sop.md"
    assert_includes hrefs, "https://example.com"
    assert_includes response.body, "[bad link](javascript:alert(1))"
  end

  private

  def swap_root(root)
    DocsController.send(:remove_const, :DOCS_ROOT)
    DocsController.const_set(:DOCS_ROOT, root)
  end
end

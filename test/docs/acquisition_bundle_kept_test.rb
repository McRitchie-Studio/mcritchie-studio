require "test_helper"

# The acquisition-studio GitHub repo is gone, so this bundle is the only copy off the
# laptop. It sits inside docs/agents/archive, whose frozen docs were removed on
# 2026-11-01: a later archive cleanup must not take it along.
class AcquisitionBundleKeptTest < ActiveSupport::TestCase
  DIR = Rails.root.join("docs/agents/archive/prototypes")

  test "[unit] the acquisition-studio bundle and its restore note stay in the tree" do
    bundle = DIR.join("acquisition-studio.bundle")

    assert_predicate bundle, :file?
    assert_match(/\A# v\d git bundle/, File.binread(bundle, 20))
    assert_includes DIR.join("README.md").read, "git clone --mirror"
  end
end

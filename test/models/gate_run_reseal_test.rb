require "test_helper"

# `bin/release reseal` RE-STAMPS THE G4 GATE'S SEAL (close-review-leftovers-bundle, fix 4).
#
# THE DEFECT: the ship closes G4 with metadata.seal (green/red/unsealed), and a
# reseal overwrote the release's recorded smoke seal but never that gate metadata —
# so the /deployments G4 column kept the false red the reseal had just corrected.
class GateRunResealTest < ActiveSupport::TestCase
  SLUG = "rel-reseal-gate".freeze

  def close_g4(seal:, attempt_success: true)
    GateRun.open!(subject_type: "release", subject_slug: SLUG, key: "g4_ship", source: "conductor")
    GateRun.close!(subject_type: "release", subject_slug: SLUG, key: "g4_ship", success: attempt_success,
                   source: "conductor", metadata: { "seal" => seal })
  end

  test "[unit] restamp_seal! overwrites the latest G4 attempt's seal and says when" do
    close_g4(seal: "red")
    latest = close_g4(seal: "red")

    run = GateRun.restamp_seal!(subject_slug: SLUG, seal: "green")

    assert_equal latest.id, run.id, "the NEWEST attempt carries the release's verdict"
    assert_equal "green", run.reload.metadata["seal"]
    assert run.metadata["resealed_at"].present?
    assert run.success, "a seal is non-blocking: re-stamping it never flips the gate's success"
  end

  test "[unit] restamp_seal! leaves every other key and gate alone" do
    close_g4(seal: "red")
    GateRun.close!(subject_type: "release", subject_slug: SLUG, key: "g3_candidate", success: true,
                   source: "conductor", metadata: { "seal" => "untouched" })

    GateRun.restamp_seal!(subject_slug: SLUG, seal: "green")

    g3 = GateRun.for_subject("release", SLUG).find_by(key: "g3_candidate")
    assert_equal "untouched", g3.metadata["seal"]
  end

  test "[unit] restamp_seal! is a no-op for a release with no G4 attempt" do
    assert_nil GateRun.restamp_seal!(subject_slug: "rel-never-shipped", seal: "green")
  end
end

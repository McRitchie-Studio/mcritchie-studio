# PRIOR ART on a triage finding — what already existed on the surface the
# finding describes, before the change in hand.
#
# `prior_art` is NOT NULL with default "unknown" on purpose. A nullable column
# would let "nobody looked" and "we looked and found nothing" occupy the same
# blank, and a blank always gets read as the second one. That read is not
# hypothetical: finding-6a5fdcd157b3 asserted turf-monster was "the first
# consumer where the iframe actually renders" and that the adoption PR "makes
# it user-visible". Both false — TM's DELETED view carried the identical
# unsandboxed iframe at the identical URL over the same 8 previews under the
# same CSP, so the net exposure change was ZERO. The error direction is what
# cost: it inflated urgency on a long-standing defect while implying a same-day
# ship caused it. Backfilled rows are honestly "unknown" — nobody looked.
class AddPriorArtToTriageFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :triage_findings, :prior_art, :string, null: false, default: "unknown"
    add_column :triage_findings, :prior_art_note, :text
  end
end

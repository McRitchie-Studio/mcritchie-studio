# frozen_string_literal: true

# WHERE A HIGGSFIELD CHARACTER IDENTITY LIVES.
#
# A "custom reference" is Higgsfield's persistent character identity: you post a
# set of reference photos once, they return a UUID, and every later generation
# that names that UUID renders the SAME face. Without it each call re-invents
# the person, which is why a generated cast drifts between shots.
#
# WHY NOT `appearances.reference_url`. That column already exists, the look form
# writes it, and NOTHING reads it (measured 2026-09-24: the only mentions are
# people_controller's permit list, the `url_field` in people/show, and this
# table). It was the obvious candidate and it is the wrong one, for three
# reasons:
#
#   1. It holds a URL — an INPUT, one photograph the operator points us at. The
#      Higgsfield id is an OUTPUT, an opaque vendor handle minted from a whole
#      set of photos. Storing a UUID in a column named `reference_url`, rendered
#      by a `url_field`, makes the column and its form control both lie.
#   2. One reference is built from MANY images, of which `reference_url` is at
#      most one. Overwriting it would destroy the operator's input to record the
#      result derived from it.
#   3. The identity is not usable the moment it is created. Measured against the
#      live API on 2026-09-24, the create answers `{"id": <uuid>, "status":
#      "not_ready"}` and the status then walks `queued` → `in_progress`. A bare
#      id column cannot express that, so a reader would pin a generation to an
#      identity that is still training.
#
# So the id gets its own column, the status gets one beside it, and
# `reference_url` keeps its meaning and finally acquires a READER —
# Appearances::ReferenceImages feeds it to the create as an extra reference
# photo alongside the cached ESPN headshot.
#
# `higgsfield_reference_synced_at` dates the status. Without it the word in the
# status column is undatable: `updated_at` moves whenever anyone edits the look,
# so it cannot answer "when did we last ask the vendor?" — and a status nobody
# can date is the one that quietly goes stale.
class AddHiggsfieldReferenceToAppearances < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :higgsfield_reference_id, :string
    add_column :appearances, :higgsfield_reference_status, :string
    add_column :appearances, :higgsfield_reference_synced_at, :datetime

    # UNIQUE because one vendor identity belongs to exactly one look: two looks
    # sharing an id would mean an edit to one silently repoints the other.
    # PARTIAL so the overwhelming majority of looks — which have no identity —
    # do not all collide on NULL.
    add_index :appearances, :higgsfield_reference_id,
              unique: true,
              where: "higgsfield_reference_id IS NOT NULL",
              name: "index_appearances_on_higgsfield_reference_id"
  end
end

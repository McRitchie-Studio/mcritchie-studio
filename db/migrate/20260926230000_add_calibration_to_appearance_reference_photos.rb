# THE OPERATOR'S OWN VERDICT ON EACH CANDIDATE, plus the provider's MIME type.
#
# WHY THE VERDICT LIVES ON THE CANDIDATE ROW rather than in a join table. The thing
# being judged is "this photograph, for this look", which is exactly the grain of
# `appearance_reference_photos` and exactly what its unique index on
# (appearance_slug, image_url) already enforces. A separate table would need the
# same two-column key to say the same thing, and would let a verdict outlive the
# candidate it judged.
#
# THERE IS ONE JUDGE. This records the OPERATOR's taste — the thing the machine's
# ranking is to be calibrated against — so there is deliberately no `user_id`. The
# write is admin-gated for that reason: a column that recorded everybody's opinion
# would be a different feature, and averaging strangers into the signal we are
# trying to learn from would poison it.
class AddCalibrationToAppearanceReferencePhotos < ActiveRecord::Migration[8.0]
  def change
    # NULLABLE, AND NULL IS A REAL VALUE: "the operator has not judged this one".
    # It is not the same as `drop`, and the agreement figures on the page count it
    # separately — a page reporting 100% agreement because 19 of 20 tiles were
    # never looked at would be worse than reporting nothing.
    add_column :appearance_reference_photos, :operator_verdict, :string
    add_column :appearance_reference_photos, :operator_verdict_at, :datetime

    # WHAT THE PROVIDER SAYS THE FILE IS. Reported for the operator to read, not
    # ranked on — see the note on Appearances::ImageSearch::Result#mime. Measured on
    # a real Commons answer for "Drew Lock" (2026-09-26): 10 of 20 rows were
    # `application/pdf` and 2 were `image/vnd.djvu`, which is the archive itself
    # admitting that more than half its answer was scanned books.
    add_column :appearance_reference_photos, :mime_type, :string

    # THE AGREEMENT TALLY'S INDEX. Every figure on the calibration panel is a count
    # over one look's rows grouped by (chosen, operator_verdict), and the page
    # recomputes all of them on every verdict write.
    add_index :appearance_reference_photos, [:appearance_slug, :operator_verdict],
              name: "index_reference_photos_verdict_per_look"
  end
end

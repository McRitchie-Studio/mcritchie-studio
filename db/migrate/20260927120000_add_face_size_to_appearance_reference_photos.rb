# WHAT THE CLASSIFIER MEASURED BESIDES VISIBILITY.
#
# `face_score` already holds "how clearly does this face show", and four real mints
# on 2026-09-25 proved that is NOT the question Higgsfield's prepare step answers:
# a bare-faced 556x780 sideline shot failed and a tight ESPN headshot completed, so
# FACE SIZE IN FRAME is the variable. These two columns are the measurement of it.
#
#   face_fill     0.0..1.0 — how much of the frame the head fills. Nullable, and a
#                 NULL is "nobody measured this", never "the face is tiny".
#   face_subjects how many people's faces are clearly visible. 2 or more cannot be
#                 attributed to one person, and an identity minted from a mixed
#                 subject set is a blended stranger.
#
# BOTH NULLABLE WITH NO DEFAULT, deliberately. A default of 0.0 would assert a
# measurement on every row ever filed, including the ones filed before the classifier
# was asked the question — and Appearances::MintEligibility reads an absent
# measurement as a REFUSAL to mint, so a fabricated zero would be indistinguishable
# from a real one on the page.
class AddFaceSizeToAppearanceReferencePhotos < ActiveRecord::Migration[8.1]
  def change
    add_column :appearance_reference_photos, :face_fill, :float
    add_column :appearance_reference_photos, :face_subjects, :integer
  end
end

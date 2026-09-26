# A SMALL RENDITION TO DISPLAY, SEPARATE FROM THE ONE WE MINT FROM.
#
# WHY THIS IS NOT COSMETIC. The scouting page shows every raw candidate — twenty-odd
# tiles — and Wikimedia Commons originals run 1-3 MB each. MEASURED 2026-09-26 on a real
# 20-result answer: the first two originals answered 200 and the next ones answered
# **HTTP 429**, so a third of the gallery rendered as grey alt-text boxes. A calibration
# page whose photographs do not load cannot be calibrated against. The same eight files
# fetched as 600px thumbnails answered 200 across the board at 18-460 KB.
#
# WHY A SECOND COLUMN RATHER THAN SHRINKING image_url. Those are two different jobs:
#
#   image_url  is handed to HIGGSFIELD, which fetches it server-side to build the
#              identity. It is also half of this table's unique index. Repointing it at
#              a thumbnail would silently change the mint input, and every measurement
#              recorded about what does and does not mint was taken against the
#              original.
#   thumb_url  is handed to the OPERATOR'S BROWSER, twenty times on one page.
#
# The tile therefore renders the thumbnail and LINKS to the original: judging a search
# hit means glancing at twenty and opening one.
#
# NULLABLE, because a provider that reports no thumbnail is normal — Serper has no
# equivalent field — and the reader falls back to the original.
class AddThumbUrlToAppearanceReferencePhotos < ActiveRecord::Migration[8.0]
  def change
    add_column :appearance_reference_photos, :thumb_url, :text
  end
end

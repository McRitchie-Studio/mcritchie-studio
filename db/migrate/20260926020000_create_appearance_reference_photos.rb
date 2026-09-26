# frozen_string_literal: true

# THE PHOTOGRAPHS WE FOUND, AND WHAT WE DID WITH EACH ONE.
#
# A character identity is only as good as the pictures it was built from, and
# the operator's question about this lane is not "did it mint?" but "did the
# search find the right photographs?". That question cannot be answered from
# the identity alone: by the time Higgsfield has the list, the candidates we
# REJECTED are gone, and a search that returned twenty stock-logo thumbnails
# looks identical to one that returned twenty good head-on portraits.
#
# So every candidate is filed, chosen or not, with the reason it was passed
# over. The rejects are the evidence — they are how a human judges whether the
# search is any good, and they cost nothing to keep.
#
# WHY NOT `ImageCache`, which the plan first reached for. Studio::ImageCache
# mirrors bytes into our own S3 and keys a row by (owner, purpose, VARIANT),
# unique on the variant. Twenty candidates would have to become twenty
# "variants" of one purpose — a field that means "100px wide" pressed into
# meaning "the fourth search hit" — and every row demands an `s3_key`, so
# filing a REJECT would mean paying to download and store a photograph we had
# already decided against. Keeping the candidate list is a cheap text record;
# mirroring bytes is a different job, and `ImageCache` still owns it for the
# headshots this table sits beside.
#
# WHY NOT `appearances.reference_url`. That column is the operator's typed
# INPUT, rendered by a `url_field` in the look form. Search results have a
# different author, a different lifetime and a different cardinality — many per
# look, replaced wholesale by the next search — and overloading one string
# column with them would destroy the operator's own entry to store a machine's.
class CreateAppearanceReferencePhotos < ActiveRecord::Migration[8.1]
  def change
    create_table :appearance_reference_photos do |t|
      t.string :slug, null: false
      t.string :appearance_slug, null: false

      # The image itself, and the page it was found on. TEXT rather than STRING
      # because image-search results routinely exceed varchar(255) — a CDN URL
      # with a signature query string is comfortably 400 characters.
      t.text :image_url, null: false
      t.text :page_url
      t.text :title

      # WHO FOUND IT. Not a boolean "from search", because the gallery has to
      # tell the operator's own photograph apart from the cached headshot apart
      # from a search hit — three different levels of trust, and the reason a
      # reject list is readable at all.
      t.string :source, null: false

      # The query that produced it. A search that finds nothing useful is
      # usually asking the wrong question, and without the text on the row there
      # is no way to see that from the gallery.
      t.text :query

      # Rank within that provider's answer. Providers order by their own
      # relevance and that order is information: hit 1 being wrong is a
      # different failure from hit 18 being wrong.
      t.integer :position

      # Dimensions WHEN THE PROVIDER VOLUNTEERS THEM. Nullable on purpose — the
      # Serper response shape is unverified (no credential existed when this was
      # built), so a provider that omits width/height must still file a usable
      # row rather than lose the photograph.
      t.integer :width
      t.integer :height

      # THE ANSWER TO "did this one make it into the identity?". A plain boolean
      # rather than a nullable timestamp: there is no useful third state, and
      # the gallery's whole job is to split the set in two.
      t.boolean :chosen, null: false, default: false

      # HOW CLEARLY THIS PHOTOGRAPH SHOWS THE PERSON'S FACE, 0.0 to 1.0, as judged
      # by Appearances::FaceVisibility. A character identity is built from faces and
      # a helmet occludes exactly the features it is built from, so this is the
      # ranking signal — not `position`, which is the provider's opinion about
      # relevance and says nothing about whether you can see anyone.
      #
      # NULLABLE, AND NULL MEANS "NOBODY LOOKED", never "no face". The classifier
      # bills per image so only a shortlist is ever scored, and with no credential
      # configured nothing is. Storing 0.0 for an unscored row would assert a
      # judgement nothing made — and would sort a perfectly good photograph to the
      # bottom on the strength of an absent credential.
      t.float :face_score

      # Why it did not make it — "unfetchable", "duplicate", "face_obscured",
      # "beyond_limit".
      # Blank on a chosen row. Without this a reject is indistinguishable from a
      # photograph nobody got round to, which is the difference between "the
      # search is bad" and "the picker is bad".
      t.datetime :found_at
      t.string :rejection_reason

      t.timestamps
    end

    add_index :appearance_reference_photos, :slug, unique: true

    # The gallery's own query: one look's photographs, chosen first.
    add_index :appearance_reference_photos, [:appearance_slug, :chosen],
              name: "index_reference_photos_per_look"

    # ONE ROW PER PHOTOGRAPH PER LOOK. A re-search re-offers most of the same
    # URLs, and two operators clicking Search at once would otherwise double
    # every candidate. Enforced in the database rather than in the picker
    # because a uniqueness check in Ruby loses that race by construction.
    #
    # SAFE TO INDEX A TEXT COLUMN HERE ONLY BECAUSE the model caps `image_url`
    # at 2,048 characters. Postgres refuses a btree entry over ~2,704 bytes at
    # INSERT time, so an uncapped text column would turn one freakishly long
    # search hit into a 500 on the search action.
    add_index :appearance_reference_photos, [:appearance_slug, :image_url],
              unique: true, name: "index_reference_photos_unique_per_look"
  end
end

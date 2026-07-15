# View helpers for the Pokédex collection grid.
module PokemonHelper
  # The artwork treatment for a collection state. Each species has ONE image on S3, so
  # the state is a CSS filter over that image (defined in app/assets/tailwind/
  # application.css) rather than a second asset. Caught art is untouched — you own it.
  #
  # Both the cell's own artwork and its evolution circles run through this, so a next
  # form you have never seen stays a silhouette even on a cell you have caught.
  DEX_ART_CLASSES = {
    caught: "",
    seen: "dex-art-seen",
    unseen: "dex-art-unseen"
  }.freeze

  def dex_art_class(entry)
    DEX_ART_CLASSES.fetch(entry.state, DEX_ART_CLASSES[:unseen])
  end
end

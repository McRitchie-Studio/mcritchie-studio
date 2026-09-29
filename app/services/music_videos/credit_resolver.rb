module MusicVideos
  # Resolves a credited name to one Artist: exact name (any case) first, then an
  # alias. No match or more than one is a reason for the operator, never a guess
  # and never a new artist.
  class CreditResolver
    Result = Struct.new(:artist, :reason)

    def resolve(name)
      by_name = Artist.where("LOWER(name) = ?", name.downcase).to_a
      return pick(by_name) if by_name.any?

      slugs = ArtistAlias.where("LOWER(name) = ?", name.downcase).distinct.pluck(:artist_slug)
      pick(Artist.where(slug: slugs).to_a)
    end

    def known?(name)
      Artist.where("LOWER(name) = ?", name.downcase).exists? ||
        ArtistAlias.where("LOWER(name) = ?", name.downcase).exists?
    end

    private

    def pick(artists)
      return Result.new(artists.first, nil) if artists.one?

      Result.new(nil, artists.empty? ? "no_match" : "ambiguous")
    end
  end
end

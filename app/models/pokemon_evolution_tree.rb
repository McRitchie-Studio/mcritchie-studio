# Gen-1 evolution families used for subagent mascot allocation. The Pokémon
# reference table intentionally remains identity-only; this service owns the
# small piece of behavior that needs family membership.
class PokemonEvolutionTree
  GROUPS = [
    %w[bulbasaur ivysaur venusaur],
    %w[charmander charmeleon charizard],
    %w[squirtle wartortle blastoise],
    %w[caterpie metapod butterfree],
    %w[weedle kakuna beedrill],
    %w[pidgey pidgeotto pidgeot],
    %w[rattata raticate],
    %w[spearow fearow],
    %w[ekans arbok],
    %w[pikachu raichu],
    %w[sandshrew sandslash],
    %w[nidoran-f nidorina nidoqueen],
    %w[nidoran-m nidorino nidoking],
    %w[clefairy clefable],
    %w[vulpix ninetales],
    %w[jigglypuff wigglytuff],
    %w[zubat golbat],
    %w[oddish gloom vileplume],
    %w[paras parasect],
    %w[venonat venomoth],
    %w[diglett dugtrio],
    %w[meowth persian],
    %w[psyduck golduck],
    %w[mankey primeape],
    %w[growlithe arcanine],
    %w[poliwag poliwhirl poliwrath],
    %w[abra kadabra alakazam],
    %w[machop machoke machamp],
    %w[bellsprout weepinbell victreebel],
    %w[tentacool tentacruel],
    %w[geodude graveler golem],
    %w[ponyta rapidash],
    %w[slowpoke slowbro],
    %w[magnemite magneton],
    %w[doduo dodrio],
    %w[seel dewgong],
    %w[grimer muk],
    %w[shellder cloyster],
    %w[gastly haunter gengar],
    %w[drowzee hypno],
    %w[krabby kingler],
    %w[voltorb electrode],
    %w[exeggcute exeggutor],
    %w[cubone marowak],
    %w[koffing weezing],
    %w[rhyhorn rhydon],
    %w[horsea seadra],
    %w[goldeen seaking],
    %w[staryu starmie],
    %w[magikarp gyarados],
    %w[eevee vaporeon jolteon flareon],
    %w[omanyte omastar],
    %w[kabuto kabutops],
    %w[dratini dragonair dragonite]
  ].map(&:freeze).freeze

  BY_SLUG = GROUPS.each_with_object({}) do |tree, index|
    tree.each { |slug| index[slug] = tree }
  end.freeze

  def self.for(slug)
    key = slug.to_s.strip
    return [] if key.empty?

    BY_SLUG.fetch(key, [key])
  end
end

require "test_helper"

# [integration] /build's "Built with McRitchie Studio" gallery, rendered from the
# real config/build_examples.yml: Turf Monster has a card, and Cyvasse and Turf
# Monster show and link to their own domains (cyvasse.xyz, turfmonster.media),
# not the old mcritchie.studio host that only redirects.
class BuildGalleryCardsTest < ActionDispatch::IntegrationTest
  def card_for(host)
    css_select("[data-test='build-example']").find { |a| URI.parse(a["href"]).host == host }
  end

  test "[integration] the gallery lists Turf Monster, and Cyvasse and Turf Monster on their own domains" do
    get build_path
    assert_response :success

    { "cyvasse.xyz" => "Cyvasse", "turfmonster.media" => "Turf Monster" }.each do |host, name|
      card = card_for(host)
      assert card, "a card links to https://#{host}"
      assert_equal "https://#{host}", card["href"]
      assert_equal "_blank", card["target"]
      assert_equal name, card.at_css("[data-test='build-example-name']").text.strip
      assert_equal host, card.at_css("[data-test='build-example-host']").text.strip, "the card shows its own domain"
      assert card.at_css("[data-test='build-example-image']"), "#{name} has its still"
    end

    hosts = css_select("[data-test='build-example']").map { |a| URI.parse(a["href"]).host }
    assert_equal %w[cyvasse.xyz turfmonster.media], hosts.first(2), "the two lead the row"
    refute_includes hosts, "cyvasse.mcritchie.studio", "the redirecting host is gone"
  end
end

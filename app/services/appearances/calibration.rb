module Appearances
  # HOW FAR THE MACHINE'S TASTE AND THE OPERATOR'S AGREE, on one look.
  #
  # THIS IS THE POINT OF THE SCOUTING PAGE. A page that only showed what the search
  # found and what the ranker picked would be a report: the operator reads it, forms
  # an opinion, and the opinion stays in his head. Recording his verdict beside the
  # machine's turns the same page into a LABELLED SET — the only thing that can tell
  # a future change to the ranking whether it made things better or worse.
  #
  # IT MEASURES, IT DOES NOT SCORE ANYBODY. Nothing here feeds the ranking today,
  # and it must not start doing so quietly: a ranker trained on this in the same
  # commit that collects it would have no held-out data left to prove it improved.
  class Calibration
    # THE FOUR CELLS, IN THE ORDER THE PANEL PRINTS THEM — agreement first, then the
    # two disagreements, because the disagreements are what the reader is looking
    # for and they should not be buried between two large agreeable numbers.
    STATES = [:agreed_keep, :agreed_reject, :machine_overpicked, :operator_promoted].freeze

    Tally = Struct.new(:counts, :total, :judged, keyword_init: true) do
      def unjudged = total - judged

      def [](state) = counts.fetch(state, 0)

      def agreed = self[:agreed_keep] + self[:agreed_reject]
      def disagreed = self[:machine_overpicked] + self[:operator_promoted]

      # nil RATHER THAN ZERO WHEN NOTHING HAS BEEN JUDGED, so the page can print
      # "not judged yet" instead of "0% agreement". A fresh look has no measured
      # disagreement, and rendering one as total disagreement would be a lie that
      # reads as a damning result.
      def agreement_rate
        return nil if judged.zero?

        (agreed.to_f / judged * 100).round
      end

      # HAS THE OPERATOR SAID ANYTHING AT ALL? The panel's whole shape depends on it.
      def started? = judged.positive?

      # THE SHARPEST SIGNAL, called out on its own because it is the cell that can
      # teach the ranker something. See AppearanceReferencePhoto#calibration_state.
      def promotions = self[:operator_promoted]

      # THE ONE SHAPE THE PAGE AND THE JSON ANSWER BOTH USE.
      #
      # Defined here rather than in the controller and again in the view because the
      # page seeds Alpine with this hash and #verdict returns the same hash after a
      # write — so any key that existed in one spelling and not the other would make
      # a figure render on first load and vanish on the first click.
      def to_h
        { states: STATES.index_with { |state| self[state] },
          total: total, judged: judged, unjudged: unjudged,
          agreed: agreed, disagreed: disagreed,
          promotions: promotions, agreement_rate: agreement_rate }
      end
    end

    def self.for(photos) = new(photos).tally

    # TAKES A LOADED COLLECTION, not a scope, and that is deliberate: the page has
    # already loaded every row to render the galleries, so counting in Ruby here
    # costs nothing and a `group(...).count` would be a second trip to Postgres to
    # re-answer a question the page is already holding the answer to.
    def initialize(photos)
      @photos = photos.to_a
    end

    def tally
      counts = @photos.each_with_object(Hash.new(0)) do |photo, acc|
        acc[photo.calibration_state] += 1
      end

      Tally.new(counts: counts, total: @photos.length,
                judged: @photos.count(&:judged?))
    end
  end
end

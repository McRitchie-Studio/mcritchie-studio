module Tiktok
  # Which team a clip's TikTok caption is about (recast pipeline, piece 19):
  # the team of the clip's LEAD SWAPPED ATHLETE, read from the alt video's swap
  # snapshot, never from the cast card as it stands now.
  #
  # THE ATHLETE, in this order, first match wins:
  #   1. the source chunk's labelled target, when the snapshot swaps them
  #      (the person the clip is cut around always leads);
  #   2. otherwise the first LEAD among the swapped people on screen in the
  #      window (MusicVideos::ClipPrompts.lead?: the target, or two clear
  #      sightings in the window), in cast order (lowest performer ordinal);
  #      a tie between two leads goes to the lower performer ordinal, which is
  #      also the lower letter (A before B);
  #   3. otherwise the first swapped person on screen in the window, in cast order;
  #   4. otherwise (the source was re-tiled so the clip has no chunk, or the
  #      window swaps nobody) the alt video's first swap, in cast order.
  #   No swap at all: refused. An alt video that swaps nobody has no athlete.
  #
  # THE TEAM of that athlete, first match wins:
  #   1. the LOOK's team (appearances.team_slug): the uniform worn in the clip,
  #      which is what the viewer sees, even if the athlete has since moved;
  #   2. the athlete's CURRENT team (athletes.team_slug). Past teams (contracts)
  #      are never read, so a traded athlete never yields two teams.
  #   Neither set: refused, naming the athlete.
  class ClipTeam
    Choice = Data.define(:entry, :team, :rule, :team_source)

    class Refused < StandardError; end

    def initialize(clip)
      @clip = clip
      @alt = clip.alt_video
      @video = @alt.music_video
      @swaps = @alt.swap_set
    end

    def call
      entry, rule = lead_entry
      raise Refused, "#{@alt.name} swaps nobody, so this clip has no athlete to caption" unless entry

      team, source = team_for(entry)
      raise Refused, "#{entry.person_name} has no team: set the team on the look #{entry.look_name.inspect} or on the athlete" unless team

      Choice.new(entry:, team:, rule:, team_source: source)
    end

    private

    def lead_entry
      chunk = @clip.chunk_in(@video.video_chunks.to_a)
      if chunk
        present = chunk.swapped_present(@swaps)
        target = chunk.target_performer && @swaps[chunk.target_performer]
        return [target, "the clip's target"] if target

        people = @video.video_performers.index_by(&:ordinal)
        lead = present.find { |e| MusicVideos::ClipPrompts.lead?(chunk, people[e.performer_ordinal]) }
        return [lead, "the first lead in the clip"] if lead
        return [present.first, "the first swapped person in the clip"] if present.any?
      end
      first = @swaps.to_a.first
      first ? [first, "the alt video's first swap"] : [nil, nil]
    end

    def team_for(entry)
      look = entry.appearance_slug && Appearance.find_by(slug: entry.appearance_slug)
      return [look.team, "look"] if look&.team

      athlete_team = Athlete.find_by(person_slug: entry.person_slug)&.team
      athlete_team ? [athlete_team, "athlete"] : [nil, nil]
    end
  end
end

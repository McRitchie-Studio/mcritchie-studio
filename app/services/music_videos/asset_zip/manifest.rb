# frozen_string_literal: true

module MusicVideos
  module AssetZip
    # What goes into an alt video's asset zip, and under which name. Pure: it
    # reads rows and builds paths and text, and fetches nothing.
    #
    # The prompt is built here at request time, with the same call and the same
    # inputs as the clip card (ClipPrompts.for with the alt video's swap
    # snapshot and the looks' current jersey numbers), so prompt.txt is the
    # card's text byte for byte. Sheets are numbered and ordered as the prompt
    # numbers them (VideoClip#swapped_present zipped with ClipPrompts.lettered),
    # and frames keep the card's order.
    #
    # Anything already known to be absent (a clip whose window was re-tiled, a
    # swap with no character sheet, a sheet on a non-https host) is listed in
    # `missing` and never becomes an entry; the Writer adds what fails to read.
    class Manifest
      # kind: :object (an R2 key), :url (an https sheet image) or :text (inline).
      Entry = Data.define(:path, :kind, :source, :label)
      Missing = Data.define(:path, :label, :reason)

      SHEET_EXTENSIONS = %w[.png .jpg .jpeg .webp].freeze

      attr_reader :root, :entries, :missing

      # The manifest of one alt video (only: a chunk ordinal for one clip's zip).
      # Every row it reads is loaded here, in a fixed number of queries
      # whatever the clip count. Raises ActiveRecord::RecordNotFound for an
      # unknown clip.
      def self.for(alt_video, only: nil, page_url: nil, at: Time.current)
        video = alt_video.music_video
        performers = video.video_performers.to_a
        chunks = video.video_chunks.to_a
        chunks.each { |chunk| chunk.association(:music_video).target = video }
        clips = alt_video.clips.to_a
        if only
          clips = clips.select { |clip| clip.chunk_ordinal == only.to_i }
          raise ActiveRecord::RecordNotFound, "#{alt_video.name} has no clip #{only}" if clips.empty?
        end
        swaps = alt_video.swap_set
        new(alt_video:, video:, performers:, clips:, chunks:, swaps:,
            sheets: Artifact.newest_character_sheets(swaps.appearance_slugs),
            numbers: ClipPrompts.numbers_for(swaps), single: only.present?, page_url:, at:)
      end

      def initialize(alt_video:, video:, performers:, clips:, chunks:, swaps:, sheets:, numbers:, single: false,
                     page_url: nil, at: Time.current)
        @alt_video = alt_video
        @video = video
        @performers = performers.sort_by(&:ordinal)
        @swaps = swaps
        @sheets = sheets
        @numbers = numbers
        @single = single
        @page_url = page_url
        @at = at
        @root = "#{video.slug}_alt_#{alt_video.number}"
        @entries = []
        @missing = []
        @clips = clips.sort_by(&:chunk_ordinal).map { |clip| clip_folder(clip, clip.chunk_in(chunks)) }
      end

      # The download's file name: the whole alt video, or one clip of it.
      def filename
        return "#{@root}.zip" unless @single

        "#{@root}_clip_#{format('%02d', @clips.first.clip.chunk_ordinal)}.zip"
      end

      def readme_path = "#{@root}/README.txt"

      # The README, with every file the zip does not carry: the manifest's own
      # list plus `also_missing` (what the Writer could not read).
      def readme(also_missing = [])
        absent = missing + Array(also_missing)
        lines = header_lines + [""] + people_lines + [""] + clip_lines + [""]
        lines << "NOT INCLUDED"
        lines << "  Nothing: every file was fetched." if absent.empty?
        absent.each { |m| lines << "  #{m.path}  #{m.label}: #{m.reason}." }
        lines << ""
        lines << "Generated versions are not included: this zip is the hand-off, not the results."
        "#{lines.join("\n")}\n"
      end

      # The clip folder name: clip_03_0040-0105 (number, window start-end as mmss).
      def self.clip_folder_name(clip) = "clip_#{format('%02d', clip.chunk_ordinal)}_#{mmss(clip.start_ms)}-#{mmss(clip.end_ms)}"

      def self.mmss(ms) = ObjectKeys.mmss(ms)

      private

      ClipFolder = Data.define(:clip, :chunk, :folder, :rows, :frames)

      def clip_folder(clip, chunk)
        folder = "#{@root}/#{self.class.clip_folder_name(clip)}"
        unless chunk
          @missing << Missing.new(path: "#{folder}/", label: clip.name,
                                  reason: "the source was re-tiled after this alt video was built, so this window has no chunk")
          return ClipFolder.new(clip:, chunk: nil, folder:, rows: [], frames: [])
        end

        add(folder, "source_clip.mp4", :object, chunk.object_key, "#{clip.name} source clip")
        add(folder, "prompt.txt", :text, ClipPrompts.for(chunk, swaps: @swaps, numbers: @numbers), "#{clip.name} prompt")
        frames = frame_entries(folder, chunk)
        rows = sheet_entries(folder, chunk)
        ClipFolder.new(clip:, chunk:, folder:, rows:, frames:)
      end

      def frame_entries(folder, chunk)
        chunk.reference_frame_list.each_with_index.map do |frame, i|
          letters = Array(frame["letters"])
          ext = File.extname(frame["object_key"].to_s).presence || ".jpg"
          name = "frame_#{i + 1}_#{letters.join}_#{self.class.mmss(frame['t_ms'])}#{ext.downcase}"
          add(folder, "frames/#{name}", :object, frame["object_key"], "Frame #{i + 1} (#{letters.join(' ')})")
          [name, frame]
        end
      end

      # [[entry, prompt row, file name or nil]] in the prompt's sheet order.
      def sheet_entries(folder, chunk)
        present = chunk.swapped_present(@swaps)
        rows = ClipPrompts.lettered(chunk, swaps: @swaps, numbers: @numbers)
        present.zip(rows).map do |entry, row|
          sheet = entry.appearance_slug && @sheets[entry.appearance_slug]
          name = "sheet_#{row.sheet}_#{row.letter}#{jersey(row.number)}_#{slug(entry.person_name)}" \
                 "#{"_#{slug(entry.look_name)}" if entry.look_name}#{sheet_extension(sheet)}"
          path = "#{folder}/sheets/#{name}"
          label = "Sheet #{row.sheet} · Person #{row.letter} · #{entry.label}"
          if sheet.nil?
            @missing << Missing.new(path:, label:, reason: "no character sheet has been built for this look yet")
            name = nil
          elsif !Appearances::FetchableUrl.https?(sheet.image_url)
            @missing << Missing.new(path:, label:, reason: "the sheet image is not on an https public host, so it was not fetched")
            name = nil
          else
            @entries << Entry.new(path:, kind: :url, source: sheet.image_url, label:)
          end
          [entry, row, name]
        end
      end

      def add(folder, name, kind, source, label)
        @entries << Entry.new(path: "#{folder}/#{name}", kind:, source:, label:)
      end

      def jersey(number) = number ? "_#{format('%02d', number)}" : ""

      def slug(text) = text.to_s.parameterize.presence || "unnamed"

      def sheet_extension(sheet)
        ext = File.extname(URI.parse(sheet&.image_url.to_s).path.to_s).downcase
        SHEET_EXTENSIONS.include?(ext) ? ext : ".png"
      rescue URI::InvalidURIError
        ".png"
      end

      def header_lines
        title = "#{@video.title} · #{@alt_video.name}"
        scope = @single ? "one clip (#{@clips.first.clip.name})" : "every clip (#{@clips.size})"
        lines = [title, "=" * title.length, "",
                 "Source video  #{@video.title} (#{@video.slug}, #{@video.kind}, #{timecode(@video.duration_ms)})",
                 "Alt video     #{@alt_video.name}, built #{@alt_video.created_at&.utc&.strftime('%Y-%m-%d %H:%M UTC')}",
                 "Swaps         #{@alt_video.swaps_summary}",
                 "This zip      #{scope}, made #{@at.utc.strftime('%Y-%m-%d %H:%M UTC')}"]
        lines << "Page          #{@page_url}" if @page_url
        lines
      end

      def people_lines
        lines = ["PEOPLE (a letter is fixed per source: Person 2 is B in every clip)"]
        @performers.each do |performer|
          swap = @swaps[performer.ordinal]
          who = if swap
                  "-> #{[number_label(swap.appearance_slug), swap.label].compact.join(' ')}" \
                    "#{' (no look was chosen)' unless swap.look_name}"
                else
                  "stays as filmed"
                end
          lines << "  #{performer.letter}  Person #{performer.ordinal} (#{performer.label})  #{who}"
        end
        lines
      end

      def clip_lines
        lines = ["CLIPS (sheets are numbered as each prompt numbers them)"]
        @clips.each do |c|
          lines << "  #{File.basename(c.folder)}/  #{c.clip.name} · #{timecode(c.clip.start_ms)}-#{timecode(c.clip.end_ms)}"
          next lines << "    (no source chunk at this window)" unless c.chunk

          lines << "    swaps nobody in this window: the prompt names nobody and there are no sheets" if c.rows.empty?
          c.rows.each do |entry, row, name|
            role = row.lead ? "lead" : "background"
            lines << "    sheet #{row.sheet}  Person #{row.letter} (#{role}) -> " \
                     "#{[number_label(entry.appearance_slug), entry.label].compact.join(' ')}  #{name ? "sheets/#{name}" : '(not included)'}"
          end
          lines << "    no lettered frames yet" if c.frames.empty?
          c.frames.each do |name, frame|
            lines << "    frames/#{name}  #{timecode(frame['t_ms'])} · #{Array(frame['letters']).join(' ')}"
          end
        end
        lines
      end

      def number_label(appearance_slug)
        number = appearance_slug && @numbers[appearance_slug]
        number ? "##{number}" : nil
      end

      def timecode(ms) = format("%d:%02d", ms.to_i / 60_000, ms.to_i / 1000 % 60)
    end
  end
end

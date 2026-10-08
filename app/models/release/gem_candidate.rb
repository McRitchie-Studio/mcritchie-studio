require "rubygems"
require "rubygems/package"
require "digest"
require "tmpdir"
require "find"

class Release
  # A gem's RELEASE CANDIDATE: the prerelease `x.y.z.rcN` that `bin/release prepare`
  # publishes for QA. The final `x.y.z` is published by `bin/release ship`, after QA
  # is green and production is granted, from the same tree.
  #
  # Decisions and comparisons only. It reads a built .gem from disk and never talks
  # to RubyGems or git; bin/release.rb supplies those reads.
  module GemCandidate
    module_function

    PATTERN    = /\A(\d+\.\d+\.\d+)\.rc(\d+)\z/
    TAG_PREFIX = "rc-" # never `v*`: the allocation and the stranded guard read `v*` tags
    VERSION_LITERAL = /version\s*=\s*["']([\w.\-]+)["']/i

    def version(final, number) = "#{final}.rc#{number}"
    def candidate?(value) = PATTERN.match?(value.to_s.strip)
    def final_of(value) = value.to_s.strip[PATTERN, 1]
    def number_of(value) = value.to_s.strip[PATTERN, 2]&.to_i
    def tag(candidate) = "#{TAG_PREFIX}#{candidate}"

    # The candidates of `final` named in a list of versions or `rc-` tags.
    def candidates_of(final, names)
      Array(names).map { |n| n.to_s.strip.delete_prefix(TAG_PREFIX) }.select { |n| final_of(n) == final.to_s }.uniq
    end

    Plan = Struct.new(:action, :version, :reason, keyword_init: true) do
      def final_live? = action == :final_live
      def reuse? = action == :reuse
      def publish? = action == :publish
    end

    # What prepare does for one gem at one release tip.
    #   :final_live  the final is already on RubyGems; consumers lock it, no candidate
    #   :reuse       a live candidate is tagged at this tip; lock it again
    #   :publish     publish the next free candidate number
    # `live` is the RubyGems listing, `tip_tags` the `rc-` tags pointing at the tip,
    # `all_tags` every `rc-` tag in the repo. A candidate is tagged AFTER its push, so
    # a tag with no live version is a yanked candidate: its number is skipped, never
    # pushed again.
    def plan(final:, live:, tip_tags:, all_tags:)
      final = final.to_s.strip
      live  = numbers(live)
      return Plan.new(action: :final_live, version: final, reason: "#{final} is already live on RubyGems") if live.include?(final)

      reusable = candidates_of(final, tip_tags).select { |c| live.include?(c) }.max_by { |c| number_of(c) }
      if reusable
        return Plan.new(action: :reuse, version: reusable,
                        reason: "#{reusable} is live and tagged at this release tip")
      end

      taken = (candidates_of(final, live) + candidates_of(final, all_tags)).map { |c| number_of(c) }
      number = taken.max.to_i + 1
      Plan.new(action: :publish, version: version(final, number),
               reason: taken.empty? ? "first candidate of #{final}" : "candidates through rc#{taken.max} belong to other trees")
    end

    def numbers(entries)
      Array(entries).map { |e| (e.is_a?(Hash) ? (e["number"] || e[:number]) : e).to_s.strip }.reject(&:empty?)
    end

    # The version file with `final` replaced by `candidate`, or nil unless the file
    # declares exactly one version literal and it is `final`. Written to a workspace
    # for the candidate build only; it is never committed.
    def rewrite_version(text, final, candidate)
      body = text.to_s
      found = body.scan(VERSION_LITERAL).flatten
      return nil unless found == [final.to_s] && final_of(candidate) == final.to_s

      body.sub(VERSION_LITERAL) { |literal| literal.sub(final.to_s, candidate.to_s) }
    end

    # What a built .gem carries, with its own version taken out of the version file:
    # { "version", "files" => { path => sha256 }, "dependencies" => [...] }. Two builds
    # of one tree at two versions have equal "files" and "dependencies".
    def manifest(gem_path, version_file:)
      package = Gem::Package.new(gem_path.to_s)
      spec    = package.spec
      own     = spec.version.to_s
      files   = {}
      Dir.mktmpdir("gem-candidate") do |dir|
        package.extract_files(dir)
        Find.find(dir) do |path|
          next unless File.file?(path)

          rel  = path.delete_prefix("#{dir}/")
          body = File.binread(path)
          body = body.gsub(own, "<version>") if rel == version_file.to_s
          files[rel] = Digest::SHA256.hexdigest(body)
        end
      end
      { "version" => own, "files" => files,
        "dependencies" => spec.dependencies.map { |d| "#{d.type} #{d.name} #{d.requirement}" }.sort }
    end

    # Every way two manifests differ, as sentences. Empty means the same contents.
    def differences(candidate, final)
      mine   = candidate.fetch("files")
      theirs = final.fetch("files")
      found  = (mine.keys - theirs.keys).sort.map { |p| "#{p} is only in the candidate" }
      found += (theirs.keys - mine.keys).sort.map { |p| "#{p} is only in the final" }
      found += (mine.keys & theirs.keys).sort.reject { |p| mine[p] == theirs[p] }.map { |p| "#{p} differs" }
      found << "runtime or development dependencies differ" unless candidate["dependencies"] == final["dependencies"]
      found
    end

    # The candidate QA tested for one gem, read from the locks QA ran:
    # `resolved` is { consumer => locked version or nil }. Returns [candidate, problems].
    # A consumer that does not lock the gem is not a witness. A consumer locking the
    # final itself is one, and names no candidate (the final was live at prepare).
    def qa_candidate(final, resolved)
      seen = resolved.to_h.transform_values { |v| v.to_s.strip }.reject { |_, v| v.empty? }
      problems = seen.reject { |_, v| v == final.to_s || final_of(v) == final.to_s }
                     .map { |repo, v| "#{repo} locks #{v}, not #{final} or a candidate of it" }
      candidates = seen.values.select { |v| final_of(v) == final.to_s }.uniq
      problems << "consumers lock different candidates (#{seen.map { |r, v| "#{r} #{v}" }.join(', ')})" if candidates.size > 1
      problems << "some consumers lock #{final} and others a candidate of it" if candidates.any? && seen.value?(final.to_s)
      [problems.empty? ? candidates.first : nil, problems]
    end
  end
end

# frozen_string_literal: true

class Release
  # THE SATELLITE DEPLOYS RUN CONCURRENTLY (task faster-steadier-production-ship,
  # part 2). Rails-free; bin/release `require`s it.
  #
  # WHY. After the gem phase (every final published, every consumer re-locked and
  # its CI read) `bin/release ship` deployed the apps one after another, so the
  # ship's wall clock was the SUM of every app's deploy: the hub's Actions run,
  # turf-monster's bin/deploy, each git_push_heroku build. They share nothing once
  # the gems are live, so all but one of them can run at once.
  #
  # THE ORDER THAT STAYS. The hub deploys FIRST and ALONE
  # (Release::ShipSequence::HUB, "a satellite never goes live against a hub that
  # hasn't caught up"): it is the SSO and source-of-truth app. A hub failure still
  # aborts the ship before any satellite moves. Only the satellites run together.
  #
  # PARTIAL FAILURE. One satellite failing does not stop, abort or roll back the
  # others: every satellite runs to its own end (each keeps its own smoke and its
  # own rollback, exactly as before), then the ship reports which apps are live and
  # which failed, records the live ones on the release, and aborts BEFORE the
  # post-deploy hooks, the seal and the shipped record. A re-run deploys only the
  # unfinished apps: a live one is skipped by deploy_already_succeeded?.
  #
  # OUTPUT. Every line a satellite's deploy prints, its own and its child
  # processes', is prefixed `[<repo>]` and also written to that app's own log
  # file; a summary follows the batch.
  module ParallelDeploy
    module_function

    # Satellites at once, by default. The board allows 5 board-writing commands
    # in flight (each satellite's deploy writes through `heroku run`), and the
    # conductor itself is one of them, so the cap is 4.
    DEFAULT_CONCURRENCY = 3
    MAX_CONCURRENCY = 4

    THREAD_REPO = :release_deploy_repo
    THREAD_LOG = :release_deploy_log

    Result = Struct.new(:repo, :ok, :error, :seconds, :log_path, keyword_init: true)

    # [[the hub, if it ships], [the satellites, in their incoming order]].
    def waves(app_groups)
      hub, rest = Array(app_groups).partition { |group| repo_of(group) == ShipSequence::HUB }
      [hub, rest]
    end

    # RELEASE_DEPLOY_CONCURRENCY, clamped to 1..MAX_CONCURRENCY; blank or junk is the default.
    def concurrency(raw)
      value = Integer(raw.to_s.strip, exception: false)
      return DEFAULT_CONCURRENCY if value.nil?

      value.clamp(1, MAX_CONCURRENCY)
    end

    # The repo a deploying thread works for, or nil on the conductor's own thread.
    def current_repo
      Thread.current[THREAD_REPO]
    end

    # Run `job` for every group, at most `concurrency` at once, and return one
    # Result per group in the groups' order. A job FAILS when it raises, including
    # the SystemExit that bin/release's abort! raises; it never stops the others.
    # `log_dir`, when given, receives one `<repo>.log` per group.
    def run(groups, concurrency:, log_dir: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, &job)
      groups = Array(groups)
      queue = Queue.new
      groups.each_with_index { |group, i| queue << [group, i] }
      results = Array.new(groups.size)
      workers = Array.new([concurrency.to_i, 1].max.clamp(1, [groups.size, 1].max)) do
        Thread.new do
          loop do
            group, index = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            results[index] = run_one(group, log_dir, clock, &job)
          end
        end
      end
      workers.each(&:join)
      results
    end

    def run_one(group, log_dir, clock)
      repo = repo_of(group)
      log_path = log_dir ? File.join(log_dir, "#{repo.gsub(/[^\w.-]/, '_')}.log") : nil
      log = log_path ? File.open(log_path, "a") : nil
      Thread.current[THREAD_REPO] = repo
      Thread.current[THREAD_LOG] = log
      started = clock.call
      error = nil
      begin
        yield group
      rescue SystemExit => e
        error = e.message.to_s.sub(/\A✗ /, "").strip
        error = "aborted (exit #{e.status})" if error.empty? || error == "exit"
      rescue StandardError => e
        error = "#{e.class}: #{e.message}"
      end
      Result.new(repo: repo, ok: error.nil?, error: error, seconds: (clock.call - started).round, log_path: log_path)
    ensure
      PrefixedOutput.flush_thread!
      Thread.current[THREAD_REPO] = nil
      Thread.current[THREAD_LOG] = nil
      log&.close
    end

    def live(results) = Array(results).select(&:ok)
    def failed(results) = Array(results).reject(&:ok)

    # The batch summary, one line per app.
    def summary_lines(results)
      Array(results).map do |r|
        mark = r.ok ? "✓ live  " : "✗ FAILED"
        detail = r.ok ? "" : " — #{r.error}"
        log = r.log_path ? "  (log: #{r.log_path})" : ""
        "    #{mark} #{r.repo} (#{r.seconds}s)#{detail}#{log}"
      end
    end

    # The abort text for a batch with a failure: what is live, what is not, and why
    # a re-run is the recovery. nil when every app went live.
    def failure_message(results, resume_cmd: "bin/release ship")
      bad = failed(results)
      return nil if bad.empty?

      good = live(results)
      "#{bad.size} of #{Array(results).size} satellite deploy#{Array(results).size == 1 ? '' : 's'} FAILED " \
        "(#{bad.map(&:repo).join(', ')}); LIVE on production: #{good.empty? ? 'none of the satellites' : good.map(&:repo).join(', ')} " \
        "(and the hub, deployed first). The failed app's own deploy owns its rollback; NOTHING was rolled back " \
        "elsewhere. Post-deploy hooks, the seal and the shipped record did NOT run. Fix what the failed deploy " \
        "names, then re-run `#{resume_cmd}`: it skips every app already live and deploys only the unfinished ones."
    end

    def repo_of(group)
      ShipSequence.group_repo(group)
    end

    # $stdout/$stderr for the parallel batch. A write from a deploying thread is
    # buffered to whole lines, each printed as `[<repo>] line` under one lock (so
    # lines from two apps never interleave mid-line) and appended, unprefixed, to
    # that thread's log. A write from any other thread passes straight through.
    class PrefixedOutput
      LOCK = Mutex.new

      def self.flush_thread!
        buffers = Thread.current[:release_deploy_buffers]
        return unless buffers

        buffers.each do |io, partial|
          io.emit_line(partial) unless partial.empty?
        end
        Thread.current[:release_deploy_buffers] = nil
      end

      def initialize(io)
        @io = io
      end

      attr_reader :io

      def write(*parts)
        text = parts.join
        repo = ParallelDeploy.current_repo
        return LOCK.synchronize { @io.write(text) } unless repo

        buffers = (Thread.current[:release_deploy_buffers] ||= {})
        pending = buffers.fetch(self, +"") + text
        lines = pending.split(/(?<=\n)/)
        buffers[self] = lines.last&.end_with?("\n") ? +"" : (lines.pop || +"")
        lines.each { |line| emit_line(line.chomp) }
        text.bytesize
      end

      def emit_line(line)
        repo = ParallelDeploy.current_repo
        log = Thread.current[THREAD_LOG]
        LOCK.synchronize do
          @io.write("[#{repo}] #{line}\n")
          log&.write("#{line}\n")
        end
      end

      def <<(text)
        write(text)
        self
      end

      def print(*args)
        write(*args.map(&:to_s))
        nil
      end

      def puts(*args)
        return write("\n") && nil if args.empty?

        args.flatten.each do |arg|
          text = arg.nil? ? "" : arg.to_s
          write(text.end_with?("\n") ? text : "#{text}\n")
        end
        nil
      end

      def printf(format, *args) = print(Kernel.format(format, *args))
      def flush = (@io.flush; self)
      def sync = true
      def sync=(_value); end
      def tty? = false
      alias isatty tty?
      def fileno = @io.fileno

      def respond_to_missing?(name, include_private = false) = @io.respond_to?(name, include_private) || super

      def method_missing(name, ...)
        return super unless @io.respond_to?(name)

        @io.public_send(name, ...)
      end
    end

    # Swap $stdout/$stderr for PrefixedOutput around the block, restoring them on
    # every exit.
    def with_prefixed_output
      out = $stdout
      err = $stderr
      $stdout = PrefixedOutput.new(out)
      $stderr = PrefixedOutput.new(err)
      yield
    ensure
      $stdout = out
      $stderr = err
    end
  end
end

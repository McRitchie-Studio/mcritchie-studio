module AgentProposals
  # Runs one CONFIRMED proposal (docs/agents/system/agent-message-loop.md,
  # "Proposals and confirm") and returns [text to post, result to store].
  #
  #   ask     the named query (AgentProposals::Queries), its text posted as is.
  #   change  a `designed` board task in the domain's repo, from the template the
  #           registry checked (title, kind, shape, accept, test, risk), with
  #           the thread recorded on it (devops.source_thread: the Discord thread,
  #           the email's admin page, or the app's web chat). A session
  #           still starts the builder (Phase 1).
  #   operate not enabled in Phase 1: refused.
  #
  # Raises on any failure; AgentProposalJob logs it and leaves the proposal open.
  class Executor
    class NotEnabled < StandardError; end

    # The satellite health reader asks use; a test sets a fake here.
    class << self
      attr_writer :fetcher

      def fetcher = @fetcher || DailyAppReport::Fetcher.new
    end

    def initialize(proposal, registry: AgentProposal.registry, fetcher: self.class.fetcher, env: ENV,
                   now: Time.current)
      @proposal = proposal
      @registry = registry
      @fetcher = fetcher
      @env = env
      @now = now
    end

    def run
      case @proposal.kind
      when "ask" then ask
      when "change" then change
      else raise NotEnabled, "operations are not enabled yet"
      end
    end

    private

    def ask
      spec = @registry.ask(@proposal.soul_slug, @proposal.capability)
      raise NotEnabled, "#{@proposal.capability} is no longer in the catalog" unless spec

      text = Queries.run(spec["query"], @proposal.params, app: spec["app"], now: @now, fetcher: @fetcher, env: @env)
      [ text, { "query" => spec["query"], "text" => text[0, 2000] } ]
    end

    def change
      spec = @registry.change(@proposal.soul_slug)
      raise NotEnabled, "changes are no longer in the catalog" unless spec

      params = @proposal.params
      thread = @proposal.thread_url
      task = Task.create!(
        title: params["title"], stage: "designed",
        description: [ @proposal.summary, ("Requested in #{@proposal.requested_in}: #{thread}" if thread),
                       ("The message: #{@proposal.message_url}" if @proposal.channel == "web" && @proposal.message_url) ]
                       .compact.join("\n\n"),
        metadata: { "devops" => { "kind" => params["kind"] || "feature", "shape" => params["shape"] || spec["default_shape"],
                  "repositories" => [ spec["repo"] ], "acceptance" => Array(params["accept"]),
                  "test_plan" => Array(params["test"]), "risk_tags" => Array(params["risk"]),
                  "source_thread" => thread }.compact }
      )
      url = @proposal.task_url(task.slug)
      [ "Opened `#{task.slug}` #{url}", { "task_slug" => task.slug, "task_url" => url } ]
    end
  end
end

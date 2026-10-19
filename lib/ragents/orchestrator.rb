# frozen_string_literal: true

module Ragents
  # Orchestrator for coordinating multiple agents.
  # Supports parallel execution, sequential workflows, and agent routing.
  #
  # @example Basic usage
  #   orchestrator = Ragents::Orchestrator.new(provider: my_provider)
  #   orchestrator.register(:researcher, ResearchAgent)
  #   orchestrator.register(:writer, WriterAgent)
  #
  #   result = orchestrator.run(:researcher, input: "Research topic X")
  #
  # @example Parallel execution
  #   results = orchestrator.parallel(
  #     [:researcher, { input: "Topic A" }],
  #     [:researcher, { input: "Topic B" }]
  #   )
  #
  # @example Sequential workflow
  #   result = orchestrator.workflow do |w|
  #     w.step(:researcher, input: "Research X")
  #     w.step(:writer) { |ctx| { input: "Write about: #{ctx.last_response}" } }
  #   end
  #
  class Orchestrator
    attr_reader :provider, :agents, :contexts, :pool

    # @param pool [Ragents::Pool, nil] when given, #parallel runs agents on
    #   the pool's long-lived Ractors instead of spawning one per agent
    def initialize(provider: nil, pool: nil, **options)
      @provider = provider
      @pool = pool
      @agents = {}
      @contexts = {}
      @options = options
    end

    # Register an agent class with a name
    # @param name [Symbol] The agent identifier
    # @param agent_class [Class] The Agent subclass
    # @param options [Hash] Default options for this agent
    def register(name, agent_class, **options)
      @agents[name.to_sym] = { class: agent_class, options: options }
      self
    end

    # Run a single agent
    # @param name [Symbol] The agent name
    # @param input [String] Input for the agent
    # @param context [Context] Optional initial context
    # @return [Context] The resulting context
    def run(name, input: nil, context: nil, **options)
      agent = build_agent(name, context: context, **options)
      agent.run(input: input)
    end

    # Run multiple agents in parallel using Ractors
    # @param tasks [Array<Array>] Array of [name, options] tuples
    # @return [Array<Context>] Results from all agents
    def parallel(*tasks)
      runs = tasks.map do |(name, opts)|
        opts ||= {}
        agent_config = @agents[name.to_sym]
        raise ArgumentError, "Unknown agent: #{name}" unless agent_config

        agent_class = agent_config[:class]
        merged_opts = agent_config[:options].merge(opts)
        context = merged_opts.delete(:context)
        input = merged_opts.delete(:input)

        if @pool
          @pool.submit(agent_class, provider: @provider, context: context, input: input, **merged_opts)
        else
          agent_class.run_async(provider: @provider, context: context, input: input, **merged_opts)
        end
      end

      # Ractor#value (Ruby 4.x) or Pool::Job#value
      runs.map(&:value)
    end

    # Execute a sequential workflow
    # @yield [Workflow] The workflow builder
    # @return [Context] The final context
    def workflow(&block)
      wf = Workflow.new(self)
      block.call(wf)
      wf.execute
    end

    # Run agents with supervisor pattern
    # @param name [Symbol] The agent name
    # @param max_restarts [Integer] Maximum restart attempts
    # @param restart_delay [Numeric] Delay between restarts
    def supervised(name, max_restarts: 3, restart_delay: 1, **options)
      restarts = 0

      begin
        run(name, **options)
      rescue StandardError => e
        restarts += 1
        if restarts <= max_restarts
          sleep(restart_delay)
          retry
        end
        raise SupervisorError, "Agent #{name} failed after #{max_restarts} restarts: #{e.message}"
      end
    end

    # Store a context for later retrieval
    def store_context(name, context)
      @contexts[name.to_sym] = context
    end

    # Retrieve a stored context
    def fetch_context(name)
      @contexts[name.to_sym]
    end

    private

    def build_agent(name, context: nil, **options)
      config = @agents[name.to_sym]
      raise ArgumentError, "Unknown agent: #{name}" unless config

      agent_class = config[:class]
      merged_options = config[:options].merge(options)

      agent_class.new(
        provider: @provider,
        context: context,
        **merged_options
      )
    end
  end

  # Workflow builder for sequential agent execution
  class Workflow
    def initialize(orchestrator)
      @orchestrator = orchestrator
      @steps = []
      @current_context = nil
    end

    # Add a step to the workflow
    # @param name [Symbol] The agent name
    # @param options [Hash] Options for the agent
    # @yield [Context] Optional block to compute options from previous context
    def step(name, **options, &block)
      @steps << { name: name, options: options, block: block }
      self
    end

    # Execute all steps sequentially
    # @return [Context] The final context
    def execute
      @steps.each do |step|
        opts = step[:options].dup

        # If a block is provided, call it with current context to get dynamic options
        if step[:block] && @current_context
          dynamic_opts = step[:block].call(@current_context)
          opts = opts.merge(dynamic_opts) if dynamic_opts.is_a?(Hash)
        end

        # Pass the previous context to maintain conversation flow
        opts[:context] = @current_context if @current_context && !opts.key?(:context)

        @current_context = @orchestrator.run(step[:name], **opts)
      end

      @current_context
    end
  end

  # Error raised when supervised agent fails
  class SupervisorError < StandardError; end
end

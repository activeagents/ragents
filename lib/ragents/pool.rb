# frozen_string_literal: true

require "etc"

module Ragents
  # A pool of long-lived worker Ractors.
  #
  # Agent.run_async spawns a Ractor per run and reads its termination value.
  # That suits one-off fan-out, but a server handling many requests wants
  # workers that stay up: spawning costs more than many tool calls take, and a
  # finished Ractor can't be reused. The pool keeps `size` Ractors running,
  # each with `threads` worker threads, and talks to them over Ractor::Port.
  #
  #   pool = Ragents::Pool.new(size: 4)
  #   context = pool.run(ResearchAgent, provider: provider, input: "...")
  #   job     = pool.submit(ResearchAgent, provider: provider, input: "...")
  #   job.value                                         # => frozen Context
  #   pool.call(MyTools, :rank, "query")                # any module function
  #   pool.call(MyTools, :narrate, "q") { |delta| ... } # streamed values
  #   pool.shutdown
  #
  # Waiting is fiber-scheduler friendly. On Ruby 4.0, Ractor::Port#receive
  # blocks its whole thread even inside a non-blocking Fiber (ruby/ruby#18819
  # proposes changing that), which would stall every other request on a
  # Falcon or Async reactor. Callers here never wait on a Port: one collector
  # thread receives every reply and hands it to the job's Thread::Queue,
  # whose #pop does yield to the scheduler.
  class Pool
    class RemoteError < Ragents::Error; end
    class ShutdownError < Ragents::Error; end

    # Executes jobs inside the worker Ractors. Modules are shareable, so it is
    # referenced, never copied.
    module Worker
      def self.perform(kind, target, args, kwargs, &emit)
        case kind
        when :agent
          agent = target.new(provider: kwargs[:provider], context: kwargs[:context], **kwargs[:options])
          agent.run(input: kwargs[:input])
        when :call
          target.public_send(args.first, *args.drop(1), **kwargs, &emit)
        end
      end
    end

    # A submitted job. #value waits (fiber-aware) for the result; with a block
    # it also yields values the job emitted, on the waiting thread.
    class Job
      def initialize
        @queue = Thread::Queue.new
        @done = false
      end

      def push(message) = @queue << message

      def value(&on_emit)
        return finish if @done

        loop do
          kind, payload = @queue.pop
          case kind
          when :emit then on_emit&.call(payload)
          else
            @done = true
            @kind = kind
            @payload = payload
            return finish
          end
        end
      end

      private

      def finish
        case @kind
        when :ok then @payload
        when :shutdown then raise ShutdownError, "pool shut down before the job finished"
        else
          message, error, backtrace = @payload
          error.set_backtrace(backtrace) if error && backtrace && error.backtrace.nil? && !error.frozen?
          raise RemoteError, message, cause: error
        end
      end
    end

    attr_reader :size, :threads

    # @param size [Integer] number of worker Ractors
    # @param threads [Integer] worker threads per Ractor (raise it for jobs
    #   that wait on IO, such as whole agent runs against a remote model)
    def initialize(size: Etc.nprocessors, threads: 1, name: "ragents")
      @size = Integer(size)
      @threads = Integer(threads)
      raise ArgumentError, "size and threads must be positive" unless @size.positive? && @threads.positive?

      @replies = Ractor::Port.new
      @free = Thread::Queue.new
      @pending = Thread::Queue.new
      @jobs = {}
      @slots = {}
      @lock = Mutex.new
      @seq = 0
      @closed = false

      @workers = Array.new(@size) do |index|
        boot = Ractor::Port.new
        ractor = Ractor.new(@replies, boot, @threads, name: "#{name}-#{index}") do |replies, boot_port, nthreads|
          inbox = Ractor::Port.new
          boot_port << inbox
          worker_threads = Array.new(nthreads) do
            Thread.new do
              while (job = inbox.receive) != :stop
                id, kind, target, args, kwargs = job
                emit = ->(value) { replies << [:emit, id, value] }
                begin
                  result = Worker.perform(kind, target, args, kwargs, &emit)
                  # A Context is frozen by design, so it is shared rather than
                  # copied; other values are copied back.
                  replies << [:ok, id, kind == :agent ? Ractor.make_shareable(result) : result]
                rescue Exception => e # rubocop:disable Lint/RescueException -- report every failure; a dead thread would lose its slot
                  # The exception is copied back as the RemoteError's cause
                  # (copies lose their backtrace, so it travels alongside).
                  begin
                    replies << [:error, id, [Pool.describe(e), e, e.backtrace]]
                  rescue StandardError
                    replies << [:error, id, [Pool.describe(e), nil, e.backtrace]]
                  end
                end
              end
            end
          end
          worker_threads.each(&:join)
          :stopped
        end
        [ractor, boot.receive]
      end
      # Interleave the slots so the first jobs spread across Ractors.
      @threads.times { @workers.each { |_ractor, inbox| @free << inbox } }

      @dispatcher = Thread.new { dispatch }
      @collector = Thread.new { collect }
      @dispatcher.name = "#{name}-dispatcher"
      @collector.name = "#{name}-collector"
    end

    # Run an agent in a worker and return its final, frozen Context.
    def run(agent_class, provider:, input: nil, context: nil, **options)
      submit(agent_class, provider: provider, input: input, context: context, **options).value
    end

    # Queue an agent run; returns a Job without waiting.
    # @raise [RactorSafetyError] if the agent can't run in a Ractor
    def submit(agent_class, provider:, input: nil, context: nil, **options)
      agent_class.ensure_ractor_safe!
      enqueue(:agent, agent_class, [], { provider: provider, input: input, context: context&.freeze, options: options })
    end

    # Call mod.method_name(*args, **kwargs) in a worker and return its value.
    # The method receives a block that emits values back to the caller's block.
    def call(mod, method_name, *args, **kwargs, &on_emit)
      raise ArgumentError, "#{mod.inspect} must be a Module (modules are shareable)" unless mod.is_a?(Module)

      enqueue(:call, mod, [method_name.to_sym, *args], kwargs).value(&on_emit)
    end

    # Stops accepting jobs, lets every submitted job finish, then stops the
    # workers.
    def shutdown
      @lock.synchronize do
        return if @closed

        @closed = true
      end
      @pending << :stop
      @dispatcher.join
      @workers.each { |_ractor, inbox| @threads.times { inbox << :stop } }
      @workers.each { |ractor, _inbox| ractor.join }
      # Every worker reply is now in the port, ahead of this marker.
      @replies << :drained
      @collector.join
      leftovers = @lock.synchronize { @jobs.values.tap { @jobs.clear } }
      leftovers.each { |job| job.push([:shutdown, nil]) }
      nil
    end

    def closed? = @closed

    def stats
      @lock.synchronize { { size: @size, threads: @threads, running: @jobs.size, free_slots: @free.size, queued: @pending.size } }
    end

    def self.describe(error)
      "#{error.class}: #{error.message}"
    end

    private

    def enqueue(kind, target, args, kwargs)
      job = Job.new
      @lock.synchronize do
        raise ShutdownError, "pool is shut down" if @closed

        @seq += 1
        @jobs[@seq] = job
        @pending << [@seq, kind, target, args, kwargs]
      end
      job
    end

    # Hands queued jobs to free worker slots, so #submit never blocks.
    def dispatch
      while (job = @pending.pop) != :stop
        inbox = @free.pop
        id = job.first
        @lock.synchronize { @slots[id] = inbox }
        begin
          inbox << job
        rescue StandardError => e
          # The job's arguments couldn't be copied into the worker.
          finish(id, :error, ["can't send job to a worker Ractor (#{Pool.describe(e)})", nil, nil])
        end
      end
    end

    def collect
      while (reply = @replies.receive) != :drained
        kind, id, payload = reply
        if kind == :emit
          @lock.synchronize { @jobs[id] }&.push([kind, payload])
        else
          finish(id, kind, payload)
        end
      end
    end

    def finish(id, kind, payload)
      job, inbox = @lock.synchronize { [@jobs.delete(id), @slots.delete(id)] }
      @free << inbox if inbox
      job&.push([kind, payload])
    end
  end
end

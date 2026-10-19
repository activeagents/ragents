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
      # Runs one job and always sends exactly one final reply for it.
      def self.run(job, replies)
        id, kind, target, args, kwargs = job
        replied = false
        emit = ->(value) { replies << [ :emit, id, value ] }
        begin
          result = perform(kind, target, args, kwargs, &emit)
          # A Context is frozen by design, so it is shared rather than copied;
          # other values are copied back.
          replies << [ :ok, id, kind == :agent ? Ractor.make_shareable(result) : result ]
          replied = true
        rescue Exception => e # rubocop:disable Lint/RescueException -- report every failure to the caller
          report_error(replies, id, e)
          replied = true
        ensure
          # Thread.exit or Thread#kill inside the job skip the rescue.
          replies << [ :error, id, [ "job ended without a result (its worker thread exited)", nil, nil ] ] unless replied
        end
      end

      # The exception is copied back as the RemoteError's cause; copies lose
      # their backtrace, so it travels alongside.
      def self.report_error(replies, id, error)
        message = begin
          "#{error.class}: #{error.message}"
        rescue Exception # rubocop:disable Lint/RescueException -- a broken #message must not lose the reply
          error.class.name.to_s
        end
        backtrace = error.backtrace if error.respond_to?(:backtrace)
        begin
          replies << [ :error, id, [ message, error, backtrace ] ]
        rescue Exception # rubocop:disable Lint/RescueException -- the exception itself couldn't be copied
          replies << [ :error, id, [ message, nil, nil ] ]
        end
      end

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
      @staging = Ractor::Port.new
      @free = Thread::Queue.new
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
          stopped = Thread::Queue.new
          # Each worker thread serves jobs until it receives :stop. A job that
          # ends its thread (Thread.exit, Thread#kill) is reported as failed and
          # a replacement thread takes over, so the slot isn't lost.
          serve = lambda do
            stop = false
            begin
              until stop
                job = inbox.receive
                if job == :stop
                  stop = true
                else
                  Worker.run(job, replies)
                end
              end
              stopped << true
            ensure
              Thread.new(&serve) unless stop
            end
          end
          nthreads.times { Thread.new(&serve) }
          nthreads.times { stopped.pop }
          :stopped
        end
        [ ractor, boot.receive ]
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

      enqueue(:call, mod, [ method_name.to_sym, *args ], kwargs).value(&on_emit)
    end

    # Stops accepting jobs, lets every submitted job finish, then stops the
    # workers.
    def shutdown
      @lock.synchronize do
        return if @closed

        @closed = true
      end
      @staging << :stop
      @dispatcher.join
      @workers.each { |_ractor, inbox| @threads.times { inbox << :stop } }
      @workers.each { |ractor, _inbox| ractor.join }
      # Every worker reply is now in the port, ahead of this marker.
      @replies << :drained
      @collector.join
      leftovers = @lock.synchronize { @jobs.values.tap { @jobs.clear } }
      leftovers.each { |job| job.push([ :shutdown, nil ]) }
      nil
    end

    def closed? = @closed

    def stats
      @lock.synchronize do
        { size: @size, threads: @threads, running: @slots.size, waiting: @jobs.size - @slots.size, free_slots: @free.size }
      end
    end

    def self.describe(error)
      "#{error.class}: #{error.message}"
    end

    private

    def enqueue(kind, target, args, kwargs)
      job = Job.new
      @lock.synchronize do
        raise ShutdownError, "pool is shut down" if @closed

        id = @seq += 1
        begin
          # Sending copies the arguments now, so changing them after
          # submitting doesn't change the job, and arguments that can't
          # enter a Ractor fail here, in the caller.
          @staging << [ id, kind, target, args, kwargs ]
        rescue StandardError => e
          raise ArgumentError, "can't send the job's arguments to a worker Ractor (#{Pool.describe(e)})"
        end
        @jobs[id] = job
      end
      job
    end

    # Hands staged jobs to free worker slots, so #submit never blocks.
    def dispatch
      while (job = @staging.receive) != :stop
        id = job.first
        inbox = @free.pop
        @lock.synchronize { @slots[id] = inbox }
        begin
          inbox.send(job, move: true) # already a private copy: move it, don't copy again
        rescue StandardError => e
          finish(id, :error, [ "can't send job to a worker Ractor (#{Pool.describe(e)})", nil, nil ])
        end
      end
    end

    def collect
      while (reply = @replies.receive) != :drained
        kind, id, payload = reply
        if kind == :emit
          @lock.synchronize { @jobs[id] }&.push([ kind, payload ])
        else
          finish(id, kind, payload)
        end
      end
    end

    def finish(id, kind, payload)
      job, inbox = @lock.synchronize { [ @jobs.delete(id), @slots.delete(id) ] }
      @free << inbox if inbox
      job&.push([ kind, payload ])
    end
  end
end

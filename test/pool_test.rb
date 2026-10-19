# frozen_string_literal: true

require "test_helper"
require "support/test_scheduler"

class PoolTest < Minitest::Test
  class EchoAgent < Ragents::Agent
    system_prompt "You echo."

    tool :echo do
      description "Echo"
      parameter :text, type: :string, required: true
      execute { |text:| "echo:#{text}" }
    end
  end

  module Jobs
    def self.add(a, b) = a + b
    def self.whoami = Ractor.current.name
    def self.nap(seconds) = sleep(seconds) && seconds
    def self.boom = raise(ArgumentError, "bad input")
    def self.count_to(n, &emit)
      1.upto(n) { |i| emit.call(i) }
      :counted
    end
    def self.with_options(text, upcase: false) = upcase ? text.upcase : text
  end

  def setup
    @pool = Ragents::Pool.new(size: 2, threads: 2, name: "test")
  end

  def teardown
    @pool.shutdown
  end

  def test_runs_an_agent_with_tools
    provider = Ragents::Providers::Test.new
    provider.stub_tool_call(name: :echo, arguments: { text: "hi" })
    provider.stub_response(content: "done")

    context = @pool.run(EchoAgent, provider: provider, input: "go")

    assert_equal "done", context.last_message.content
    assert_equal "echo:hi", context.messages[3].content
    assert Ractor.shareable?(context)
  end

  def test_continues_a_conversation_from_a_given_context
    provider = Ragents::Providers::Test.new
    provider.stub_response(content: "second")
    first = Ragents::Context.new(messages: [Ragents::Message.user("one"), Ragents::Message.assistant("first")])

    context = @pool.run(EchoAgent, provider: provider, context: first, input: "two")

    assert_equal %w[one first two second], context.conversation_messages.map(&:content)
  end

  def test_calls_module_functions_with_args_and_kwargs
    assert_equal 5, @pool.call(Jobs, :add, 2, 3)
    assert_equal "HI", @pool.call(Jobs, :with_options, "hi", upcase: true)
  end

  def test_jobs_spread_across_worker_ractors
    jobs = Array.new(8) { @pool.send(:enqueue, :call, Jobs, [:whoami], {}) }
    names = jobs.map(&:value).uniq.sort

    assert_equal %w[test-0 test-1], names
  end

  def test_submit_does_not_block_when_workers_are_busy
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    jobs = Array.new(6) { @pool.send(:enqueue, :call, Jobs, [:nap, 0.1], {}) }
    submitted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator submitted, :<, 0.05
    assert_equal [0.1] * 6, jobs.map(&:value)
  end

  def test_emitted_values_are_yielded_in_order_on_the_caller
    seen = []
    result = @pool.call(Jobs, :count_to, 5) { |i| seen << [i, Thread.current] }

    assert_equal :counted, result
    assert_equal [1, 2, 3, 4, 5], seen.map(&:first)
    assert(seen.all? { |_, thread| thread == Thread.current })
  end

  def test_errors_come_back_with_the_remote_exception_as_cause
    error = assert_raises(Ragents::Pool::RemoteError) { @pool.call(Jobs, :boom) }

    assert_equal "ArgumentError: bad input", error.message
    assert_instance_of ArgumentError, error.cause
    # The worker survives and keeps its slot.
    assert_equal 3, @pool.call(Jobs, :add, 1, 2)
  end

  def test_unsafe_agents_are_rejected_before_anything_is_queued
    calls = []
    unsafe = Class.new(Ragents::Agent) do
      tool :record do
        description "Record"
        execute { (calls << 1).size }
      end
    end

    assert_raises(Ragents::RactorSafetyError) { @pool.submit(unsafe, provider: Ragents::Providers::Test.new) }
    assert_equal 0, @pool.stats[:running]
  end

  def test_arguments_that_cannot_be_sent_fail_the_job_not_the_pool
    error = assert_raises(Ragents::Pool::RemoteError) { @pool.call(Jobs, :add, Thread::Queue.new, 1) }

    assert_match(/can't send job to a worker Ractor/, error.message)
    assert_equal 3, @pool.call(Jobs, :add, 1, 2)
  end

  def test_waiting_yields_to_other_fibers
    events = Thread::Queue.new
    Thread.new do
      Fiber.set_scheduler(TestScheduler.new)
      Fiber.schedule do
        @pool.call(Jobs, :nap, 0.3)
        events << :pool_job_done
      end
      Fiber.schedule do
        5.times { sleep 0.02 }
        events << :ticker_done
      end
    end.join

    # If the pool blocked the thread, the ticker could only finish afterwards.
    assert_equal %i[ticker_done pool_job_done], [events.pop, events.pop]
  end

  def test_many_fibers_share_one_thread
    results = []
    Thread.new do
      Fiber.set_scheduler(TestScheduler.new)
      8.times { |i| Fiber.schedule { results << @pool.call(Jobs, :add, i, 100) } }
    end.join

    assert_equal (100..107).to_a, results.sort
  end

  def test_orchestrator_parallel_uses_the_pool
    provider = Ragents::Providers::Test.new
    provider.stub_response(content: "pooled")
    orchestrator = Ragents::Orchestrator.new(provider: provider, pool: @pool)
    orchestrator.register(:echo, EchoAgent)

    results = orchestrator.parallel([:echo, { input: "a" }], [:echo, { input: "b" }], [:echo, { input: "c" }])

    assert_equal ["pooled"] * 3, results.map { |c| c.last_message.content }
  end

  def test_shutdown_finishes_submitted_jobs_then_refuses_new_ones
    pool = Ragents::Pool.new(size: 1, threads: 1)
    jobs = Array.new(3) { pool.send(:enqueue, :call, Jobs, [:nap, 0.05], {}) }
    pool.shutdown

    assert_equal [0.05] * 3, jobs.map(&:value)
    assert_raises(Ragents::Pool::ShutdownError) { pool.call(Jobs, :add, 1, 2) }
    assert_nil pool.shutdown
  end
end

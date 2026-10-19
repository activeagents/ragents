# frozen_string_literal: true

# A minimal Fiber::Scheduler for tests: enough to show whether waiting code
# yields to other fibers (block/unblock, sleep). No IO hooks.
class TestScheduler
  def initialize
    @ready = []
    @timers = []
    @blocked = {}
    @unblocked = []
    @lock = Thread::Mutex.new
    @wake_r, @wake_w = IO.pipe
  end

  def fiber(&block)
    fiber = Fiber.new(blocking: false, &block)
    fiber.resume
    fiber
  end

  def block(_blocker, timeout = nil)
    fiber = Fiber.current
    if timeout
      @timers << [ now + timeout, fiber ]
    else
      @blocked[fiber] = true
    end
    Fiber.yield
  ensure
    @blocked.delete(fiber)
    @timers.reject! { |_, f| f.equal?(fiber) }
  end

  # May be called from other threads.
  def unblock(_blocker, fiber)
    Fiber.blocking { @lock.synchronize { @unblocked << [ fiber, nil ] } }
    @wake_w.write_nonblock(".", exception: false)
  end

  # Required by Fiber.set_scheduler from Ruby 4.1: raise in a waiting fiber.
  def fiber_interrupt(fiber, exception)
    Fiber.blocking { @lock.synchronize { @unblocked << [ fiber, exception ] } }
    @wake_w.write_nonblock(".", exception: false)
  end

  def kernel_sleep(duration = nil)
    block(:sleep, duration)
  end

  # Required by Fiber.set_scheduler. Tests don't do IO in fibers, so this just
  # waits on the calling thread.
  def io_wait(io, events, timeout)
    Fiber.blocking do
      readers = (events & IO::READABLE).zero? ? nil : [ io ]
      writers = (events & IO::WRITABLE).zero? ? nil : [ io ]
      IO.select(readers, writers, nil, timeout) ? events : false
    end
  end

  def close
    run
    @wake_r.close
    @wake_w.close
  end

  private

  def run
    loop do
      wake_unblocked
      due, @timers = @timers.partition { |at, _| at <= now }
      @ready.concat(due.map { |_, fiber| [ fiber, nil ] })
      until @ready.empty?
        fiber, exception = @ready.shift
        next unless fiber.alive?

        exception ? fiber.raise(exception) : fiber.resume
      end
      wake_unblocked
      next unless @ready.empty?
      break if @timers.empty? && @blocked.empty?

      timeout = @timers.empty? ? nil : [ @timers.map(&:first).min - now, 0 ].max
      IO.select([ @wake_r ], nil, nil, timeout)
      @wake_r.read_nonblock(4096, exception: false)
    end
  end

  def wake_unblocked
    entries = @lock.synchronize { @unblocked.slice!(0..) }
    entries.each do |fiber, exception|
      @blocked.delete(fiber)
      @timers.reject! { |_, f| f.equal?(fiber) }
      @ready << [ fiber, exception ]
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

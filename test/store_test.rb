# frozen_string_literal: true

require "test_helper"

class StoreTest < Minitest::Test
  def setup
    @store = Ragents::Store.new({ greeting: "hello" })
  end

  def teardown
    @store.stop
  end

  def test_basic_operations
    assert_equal "hello", @store[:greeting]
    @store[:topic] = "ractors"
    assert_equal "ractors", @store.get(:topic)
    assert_equal :none, @store.fetch(:missing, :none)
    assert_equal 1, @store.append(:facts, "a")
    assert_equal 2, @store.append(:facts, "b")
    assert_equal %w[a b], @store.get(:facts)
    assert_equal "ractors", @store.delete(:topic)
    assert_equal %i[greeting facts], @store.keys
    assert_equal({ greeting: "hello", facts: %w[a b] }, @store.to_h)
  end

  def test_store_is_shareable_and_usable_from_other_ractors
    assert Ractor.shareable?(@store)

    writers = Array.new(4) do |w|
      Ractor.new(@store, w) do |store, id|
        10.times { |i| store.append(:log, [id, i]) }
        store.update(:count) { |n| (n || 0) + 10 }
        :done
      end
    end
    writers.each(&:join)

    log = @store.get(:log)
    assert_equal 40, log.size
    assert_equal [0, 1, 2, 3], log.map(&:first).uniq.sort
    # Each writer's own entries arrive in its order.
    log.group_by(&:first).each_value { |entries| assert_equal (0..9).to_a, entries.map(&:last) }
    assert_equal 40, @store.get(:count)
  end

  def test_values_are_copied_in_and_out
    list = ["a"]
    @store.put(:list, list)
    list << "b"
    copy = @store.get(:list)
    copy << "c"

    assert_equal ["a"], @store.get(:list)
  end

  def test_update_blocks_may_capture_shareable_values_only
    increment = 5
    assert_equal 5, @store.update(:n) { |n| (n || 0) + increment }

    seen = []
    assert_raises(Ractor::IsolationError) { @store.update(:n) { |n| seen << n } }
  end

  def test_errors_inside_the_store_are_reported_and_it_keeps_running
    @store.put(:n, 1)
    error = assert_raises(Ragents::Error) { @store.update(:n) { |n| n.fetch(:x) } }
    assert_match(/NoMethodError/, error.message)
    assert_equal 1, @store.get(:n)
  end

  def test_stop_is_idempotent
    store = Ragents::Store.new
    store.stop
    assert_nil store.stop
  end
end

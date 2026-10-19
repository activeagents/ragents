# frozen_string_literal: true

require "test_helper"

class ContextTest < Minitest::Test
  def test_empty_context
    ctx = Ragents::Context.new
    assert ctx.empty?
    assert_equal 0, ctx.size
  end

  def test_add_message
    ctx = Ragents::Context.new
    ctx = ctx.add_message(user_message("Hello"))

    assert_equal 1, ctx.size
    assert_equal "Hello", ctx.last_message.content
  end

  def test_immutability
    ctx1 = Ragents::Context.new
    ctx2 = ctx1.add_message(user_message("Hello"))

    assert ctx1.empty?
    refute ctx2.empty?
    assert ctx1.frozen?
    assert ctx2.frozen?
  end

  def test_add_multiple_messages
    ctx = Ragents::Context.new
    ctx = ctx.add_messages(
      user_message("Hello"),
      assistant_message("Hi there!")
    )

    assert_equal 2, ctx.size
  end

  def test_system_message
    ctx = Ragents::Context.new(messages: [
      system_message("You are helpful"),
      user_message("Hello")
    ])

    assert_equal "You are helpful", ctx.system_message.content
    assert_equal 1, ctx.conversation_messages.size
  end

  def test_last_assistant_message
    ctx = Ragents::Context.new(messages: [
      user_message("Hello"),
      assistant_message("Hi!"),
      user_message("How are you?"),
      assistant_message("I'm good!")
    ])

    assert_equal "I'm good!", ctx.last_assistant_message.content
  end

  def test_pending_tool_calls
    tool_calls = [ { id: "call_1", name: "search", arguments: { query: "test" } } ]
    ctx = Ragents::Context.new(messages: [
      user_message("Search for X"),
      assistant_message("Let me search", tool_calls: tool_calls)
    ])

    assert ctx.pending_tool_calls?
    assert_equal 1, ctx.pending_tool_calls.size
  end

  def test_truncate
    messages = (1..10).map { |i| user_message("Message #{i}") }
    ctx = Ragents::Context.new(messages: messages)

    truncated = ctx.truncate(max_messages: 5)
    assert_equal 5, truncated.size
    assert_equal "Message 6", truncated.messages.first.content
  end

  def test_truncate_keeps_system
    ctx = Ragents::Context.new(messages: [
      system_message("System prompt"),
      user_message("Msg 1"),
      user_message("Msg 2"),
      user_message("Msg 3"),
      user_message("Msg 4")
    ])

    truncated = ctx.truncate(max_messages: 3, keep_system: true)
    assert_equal 3, truncated.size
    assert truncated.messages.first.system?
  end

  def test_to_a
    ctx = Ragents::Context.new(messages: [ user_message("Hello") ])
    arr = ctx.to_a

    assert_equal 1, arr.size
    assert_equal :user, arr.first[:role]
  end

  def test_metadata
    ctx = Ragents::Context.new(metadata: { session_id: "123" })
    assert_equal "123", ctx.metadata[:session_id]

    ctx2 = ctx.with_metadata(user_id: "456")
    assert_equal "123", ctx2.metadata[:session_id]
    assert_equal "456", ctx2.metadata[:user_id]
  end

  def test_fork
    ctx = Ragents::Context.new(messages: [ user_message("Hello") ])
    forked = ctx.fork(branch: "experiment")

    assert_equal 1, forked.size
    assert_equal "experiment", forked.metadata[:branch]
    assert forked.metadata[:forked_at]
  end

  def test_enumerable
    ctx = Ragents::Context.new(messages: [
      user_message("A"),
      user_message("B")
    ])

    contents = ctx.map(&:content)
    assert_equal [ "A", "B" ], contents
  end
end

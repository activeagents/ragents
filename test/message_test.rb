# frozen_string_literal: true

require "test_helper"

class MessageTest < Minitest::Test
  def test_user_message
    msg = Ragents::Message.user("Hello")
    assert_equal :user, msg.role
    assert_equal "Hello", msg.content
    assert msg.user?
    refute msg.assistant?
  end

  def test_assistant_message
    msg = Ragents::Message.assistant("Hi there!")
    assert_equal :assistant, msg.role
    assert_equal "Hi there!", msg.content
    assert msg.assistant?
  end

  def test_system_message
    msg = Ragents::Message.system("You are helpful")
    assert_equal :system, msg.role
    assert msg.system?
  end

  def test_tool_message
    msg = Ragents::Message.tool("result", tool_call_id: "call_123", name: "my_tool")
    assert_equal :tool, msg.role
    assert_equal "result", msg.content
    assert_equal "call_123", msg.tool_call_id
    assert_equal "my_tool", msg.name
    assert msg.tool?
  end

  def test_message_with_tool_calls
    tool_calls = [{ id: "call_1", name: "search", arguments: { query: "test" } }]
    msg = Ragents::Message.assistant("Let me search", tool_calls: tool_calls)

    assert msg.has_tool_calls?
    assert_equal 1, msg.tool_calls.size
  end

  def test_message_is_frozen
    msg = Ragents::Message.user("Hello")
    assert msg.frozen?
  end

  def test_to_h
    msg = Ragents::Message.user("Hello")
    hash = msg.to_h

    assert_equal :user, hash[:role]
    assert_equal "Hello", hash[:content]
  end

  def test_invalid_role_raises
    assert_raises(ArgumentError) do
      Ragents::Message.new(role: :invalid, content: "test")
    end
  end

  def test_equality
    msg1 = Ragents::Message.user("Hello")
    msg2 = Ragents::Message.user("Hello")
    msg3 = Ragents::Message.user("World")

    assert_equal msg1, msg2
    refute_equal msg1, msg3
  end
end

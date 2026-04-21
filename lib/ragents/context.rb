# frozen_string_literal: true

require "time"

module Ragents
  # Immutable conversation context.
  # Context is Ractor-shareable when frozen, enabling safe passage between Ractors.
  #
  # @example
  #   context = Ragents::Context.new
  #   context = context.add_message(Message.user("Hello"))
  #   context = context.add_message(Message.assistant("Hi there!"))
  #   context.messages.size  # => 2
  #
  class Context
    attr_reader :messages, :metadata

    def initialize(messages: [], metadata: {})
      @messages = messages.map { |m| ensure_message(m) }.freeze
      @metadata = metadata.freeze
      freeze
    end

    # Add a message and return a new Context
    def add_message(message)
      message = ensure_message(message)
      self.class.new(
        messages: @messages + [message],
        metadata: @metadata
      )
    end

    alias << add_message

    # Add multiple messages and return a new Context
    def add_messages(*new_messages)
      new_messages = new_messages.flatten.map { |m| ensure_message(m) }
      self.class.new(
        messages: @messages + new_messages,
        metadata: @metadata
      )
    end

    # Return a new Context with updated metadata
    def with_metadata(**new_metadata)
      self.class.new(
        messages: @messages,
        metadata: @metadata.merge(new_metadata)
      )
    end

    # Get the system message if present
    def system_message
      @messages.find(&:system?)
    end

    # Get all non-system messages
    def conversation_messages
      @messages.reject(&:system?)
    end

    # Get the last message
    def last_message
      @messages.last
    end

    # Get the last assistant message
    def last_assistant_message
      @messages.reverse.find(&:assistant?)
    end

    # Check if the last message has tool calls
    def pending_tool_calls?
      last_assistant_message&.has_tool_calls? || false
    end

    # Get pending tool calls from the last assistant message
    def pending_tool_calls
      return [] unless pending_tool_calls?

      last_assistant_message.tool_calls
    end

    # Count total messages
    def size
      @messages.size
    end

    alias length size

    def empty?
      @messages.empty?
    end

    # Iterate over messages
    def each(&block)
      @messages.each(&block)
    end

    include Enumerable

    # Convert to array of message hashes
    def to_a
      @messages.map(&:to_h)
    end

    # Serialize to hash
    def to_h
      {
        messages: to_a,
        metadata: @metadata
      }
    end

    # Create from hash
    def self.from_h(hash)
      messages = (hash[:messages] || hash["messages"] || []).map do |msg|
        Message.new(**symbolize_keys(msg))
      end

      metadata = hash[:metadata] || hash["metadata"] || {}

      new(messages: messages, metadata: symbolize_keys(metadata))
    end

    # Truncate context to last N messages (keeping system message)
    def truncate(max_messages:, keep_system: true)
      return self if @messages.size <= max_messages

      system_msg = system_message if keep_system
      other_messages = conversation_messages

      kept = other_messages.last(keep_system && system_msg ? max_messages - 1 : max_messages)

      self.class.new(
        messages: system_msg ? [system_msg] + kept : kept,
        metadata: @metadata
      )
    end

    # Create a fork of this context (for branching conversations)
    def fork(**new_metadata)
      self.class.new(
        messages: @messages.dup,
        metadata: @metadata.merge(new_metadata).merge(forked_at: Time.now.iso8601)
      )
    end

    # Make Ractor-shareable
    def self.make_shareable(context)
      Ractor.make_shareable(context)
    end

    private

    def ensure_message(msg)
      case msg
      when Message
        msg
      when Hash
        Message.new(**self.class.symbolize_keys(msg))
      else
        raise ArgumentError, "Expected Message or Hash, got #{msg.class}"
      end
    end

    def self.symbolize_keys(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end

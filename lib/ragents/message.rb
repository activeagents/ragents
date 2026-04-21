# frozen_string_literal: true

module Ragents
  # Immutable message value object for conversation history.
  # Messages are Ractor-shareable when frozen.
  #
  # @example
  #   message = Ragents::Message.new(role: :user, content: "Hello")
  #   message.role     # => :user
  #   message.content  # => "Hello"
  #
  class Message
    ROLES = %i[system user assistant tool].freeze

    attr_reader :role, :content, :tool_calls, :tool_call_id, :name, :metadata

    def initialize(role:, content: nil, tool_calls: nil, tool_call_id: nil, name: nil, metadata: {})
      @role = validate_role!(role)
      @content = content&.freeze
      @tool_calls = tool_calls&.map(&:freeze)&.freeze
      @tool_call_id = tool_call_id&.freeze
      @name = name&.freeze
      @metadata = metadata.freeze

      freeze
    end

    # Create a system message
    def self.system(content, **metadata)
      new(role: :system, content: content, metadata: metadata)
    end

    # Create a user message
    def self.user(content, **metadata)
      new(role: :user, content: content, metadata: metadata)
    end

    # Create an assistant message
    def self.assistant(content, tool_calls: nil, **metadata)
      new(role: :assistant, content: content, tool_calls: tool_calls, metadata: metadata)
    end

    # Create a tool result message
    def self.tool(content, tool_call_id:, name: nil, **metadata)
      new(role: :tool, content: content, tool_call_id: tool_call_id, name: name, metadata: metadata)
    end

    def system?
      role == :system
    end

    def user?
      role == :user
    end

    def assistant?
      role == :assistant
    end

    def tool?
      role == :tool
    end

    def has_tool_calls?
      !tool_calls.nil? && !tool_calls.empty?
    end

    # Convert to hash for serialization
    def to_h
      hash = { role: role }
      hash[:content] = content if content
      hash[:tool_calls] = tool_calls if tool_calls
      hash[:tool_call_id] = tool_call_id if tool_call_id
      hash[:name] = name if name
      hash[:metadata] = metadata unless metadata.empty?
      hash
    end

    def ==(other)
      return false unless other.is_a?(Message)

      role == other.role &&
        content == other.content &&
        tool_calls == other.tool_calls &&
        tool_call_id == other.tool_call_id &&
        name == other.name
    end

    alias eql? ==

    def hash
      [role, content, tool_calls, tool_call_id, name].hash
    end

    # Make Ractor-shareable
    def self.make_shareable(message)
      Ractor.make_shareable(message)
    end

    private

    def validate_role!(role)
      role = role.to_sym
      unless ROLES.include?(role)
        raise ArgumentError, "Invalid role: #{role}. Must be one of: #{ROLES.join(", ")}"
      end

      role
    end
  end
end

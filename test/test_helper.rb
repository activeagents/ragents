# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ragents"
require "minitest/autorun"

# Test provider for use in tests
module Ragents
  module TestHelpers
    def build_test_provider
      Ragents::Providers::Test.new
    end

    def build_context(*messages)
      Ragents::Context.new(messages: messages)
    end

    def user_message(content)
      Ragents::Message.user(content)
    end

    def assistant_message(content, tool_calls: nil)
      Ragents::Message.assistant(content, tool_calls: tool_calls)
    end

    def system_message(content)
      Ragents::Message.system(content)
    end
  end
end

class Minitest::Test
  include Ragents::TestHelpers
end

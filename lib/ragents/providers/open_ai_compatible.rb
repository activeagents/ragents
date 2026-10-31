# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Ragents
  module Providers
    # Provider for any OpenAI-compatible Chat Completions endpoint: OpenAI,
    # OpenRouter, Ollama, vLLM, LM Studio, LiteLLM and so on.
    #
    # It is built for Ractors. The provider object is frozen configuration and
    # Ractor-shareable, so run_async, Orchestrator#parallel and Ragents::Pool
    # pass it by reference instead of copying it. Keep-alive connections live in
    # Ractor-local storage: each Ractor opens its own and reuses them across
    # requests. It depends only on Net::HTTP and JSON, both of which work
    # inside Ractors on Ruby 4.0. (The RubyLLM provider keeps its
    # configuration in module state, which non-main Ractors can't read, so it
    # works on the main Ractor only.)
    #
    #   provider = Ragents::Providers::OpenAICompatible.new(model: "gpt-4o-mini")
    #   provider = Ragents::Providers::OpenAICompatible.openrouter(model: "anthropic/claude-haiku-5.5")
    #   provider = Ragents::Providers::OpenAICompatible.new(
    #     model: "llama3.2", base_url: "http://localhost:11434/v1", api_key: nil
    #   )
    #
    # Net::HTTP waits through the Fiber scheduler, so concurrent requests from
    # Fibers (Falcon, Async) overlap.
    class OpenAICompatible < Provider
      OPENAI_URL = "https://api.openai.com/v1"
      OPENROUTER_URL = "https://openrouter.ai/api/v1"
      # Errors from a kept-alive connection the server has since closed. Over
      # TLS an abrupt close surfaces as an SSLError ("unexpected eof").
      RETRYABLE = [ EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, OpenSSL::SSL::SSLError ].freeze
      # SSE events end with a blank line; servers may use \n, \r\n or \r.
      EVENT_END = /\r\n\r\n|\n\n|\r\r/
      LINE_END = /\r\n|\n|\r/

      # OpenRouter, with usage accounting on (responses report cost).
      def self.openrouter(model:, api_key: ENV["OPENROUTER_API_KEY"], **config)
        new(model: model, base_url: OPENROUTER_URL, api_key: api_key,
            body: { usage: { include: true } }.merge(config.delete(:body) || {}), **config)
      end

      attr_reader :model

      # @param model [String] model id sent with every request
      # @param base_url [String] endpoint root; "/chat/completions" is appended
      # @param api_key [String, nil] sent as a Bearer token when present
      # @param headers [Hash] extra request headers
      # @param body [Hash] extra fields merged into every request body
      # @param timeout [Numeric] read timeout in seconds
      # @param max_idle [Integer] idle connections kept per Ractor
      def initialize(model:, base_url: OPENAI_URL, api_key: ENV["OPENAI_API_KEY"], headers: {}, body: {},
                     timeout: 120, open_timeout: 10, keep_alive: 30, max_idle: 64)
        super(model: model, base_url: base_url, api_key: api_key, headers: headers, body: body,
              timeout: timeout, open_timeout: open_timeout, keep_alive: keep_alive, max_idle: max_idle)
        @model = @config[:model]
        @uri = URI.join(@config[:base_url].to_s.chomp("/") + "/", "chat/completions")
        # Connections are pooled per endpoint, not per provider, so creating
        # providers freely (one per API key, say) reuses the same sockets.
        @pool_key = :"ragents_http #{@uri.scheme}://#{@uri.host}:#{@uri.port}"
        @config = Shareable.value(@config).first
        Ractor.make_shareable(self)
      end

      def generate(messages:, tools: [], **_options)
        data = JSON.parse(post(request_body(messages, tools, stream: false)))
        raise APIError.new(data.dig("error", "message") || "error", response_body: data) if data["error"]

        choice = data.dig("choices", 0) or raise APIError.new("no choices in response", response_body: data)
        message = choice["message"] || {}
        tool_calls = Array(message["tool_calls"]).map do |call|
          arguments = call.dig("function", "arguments").to_s
          ToolCall.new(id: call["id"], name: call.dig("function", "name"), arguments: arguments.strip.empty? ? "{}" : arguments)
        end
        Response.new(content: message["content"], tool_calls: tool_calls, finish_reason: choice["finish_reason"],
                     usage: data["usage"] || {}, raw_response: data)
      end

      # Streams text deltas. Tool calls are not assembled from stream chunks;
      # Agent#run uses #generate.
      def stream(messages:, tools: [], **_options, &block)
        content = +""
        usage = {}
        finish_reason = nil
        post_stream(request_body(messages, tools, stream: true)) do |chunk|
          usage.merge!(chunk["usage"]) if chunk["usage"].is_a?(Hash)
          finish_reason = chunk.dig("choices", 0, "finish_reason") || finish_reason
          delta = chunk.dig("choices", 0, "delta", "content")
          next if delta.nil? || delta.empty?

          content << delta
          block&.call(delta)
        end
        Response.new(content: content, finish_reason: finish_reason || "stop", usage: usage)
      end

      protected

      def validate_config!
        raise ConfigurationError, "model is required" if @config[:model].to_s.empty?
        raise ConfigurationError, "base_url is required" if @config[:base_url].to_s.empty?
      end

      private

      def request_body(messages, tools, stream:)
        payload = { model: @model, messages: messages.map { |m| wire_message(m) }, stream: stream }
        schemas = format_tools(tools)
        payload[:tools] = schemas unless schemas.empty?
        JSON.generate(payload.merge(@config[:body]))
      end

      def wire_message(message)
        m = (message.respond_to?(:to_h) ? message.to_h : message).transform_keys(&:to_sym)
        wire = { role: m[:role].to_s, content: m[:content] }
        if m[:tool_calls]
          wire[:tool_calls] = m[:tool_calls].map do |call|
            call = call.transform_keys(&:to_sym)
            arguments = call[:arguments]
            {
              id: call[:id], type: "function",
              function: { name: call[:name].to_s, arguments: arguments.is_a?(String) ? arguments : JSON.generate(arguments || {}) }
            }
          end
        end
        wire[:tool_call_id] = m[:tool_call_id] if m[:tool_call_id]
        wire[:name] = m[:name] if m[:name] && m[:role].to_s == "tool"
        wire
      end

      def headers(extra = {})
        h = { "Content-Type" => "application/json" }
        h["Authorization"] = "Bearer #{@config[:api_key]}" if @config[:api_key]
        h.merge(@config[:headers]).merge(extra)
      end

      def post(body)
        with_connection do |http|
          request = Net::HTTP::Post.new(@uri.request_uri, headers)
          request.body = body
          response = http.request(request)
          check!(response, response.body)
          response.body
        end
      end

      def post_stream(body)
        started = false
        # Once the response has started, a failure is not retried: the caller
        # may already have seen some of the stream.
        with_connection(retry_if: -> { !started }) do |http|
          request = Net::HTTP::Post.new(@uri.request_uri, headers("Accept" => "text/event-stream"))
          request.body = body
          http.request(request) do |response|
            started = true
            check!(response, response.is_a?(Net::HTTPSuccess) ? nil : response.read_body)
            buffer = String.new(encoding: Encoding::BINARY)
            response.read_body do |chunk|
              buffer << chunk.b
              while (boundary = EVENT_END.match(buffer))
                buffer.slice!(0, boundary.end(0)).split(LINE_END).each do |line|
                  next unless line.start_with?("data:")

                  data = line.delete_prefix("data:").strip.force_encoding(Encoding::UTF_8)
                  next if data.empty? || data == "[DONE]"

                  event = JSON.parse(data)
                  raise APIError.new(event.dig("error", "message") || "stream error", response_body: event) if event["error"]

                  yield event
                end
              end
            end
          end
        end
      end

      def check!(response, body)
        return if response.is_a?(Net::HTTPSuccess)

        status = response.code.to_i
        message = "HTTP #{status}: #{body.to_s[0, 300]}"
        error =
          case status
          when 401, 403 then AuthenticationError
          when 429 then RateLimitError
          else APIError
          end
        raise error.new(message, status_code: status, response_body: body)
      end

      # Idle connections to this endpoint in the current Ractor.
      def idle_connections
        Ractor.store_if_absent(@pool_key) { Thread::Queue.new }
      end

      # Runs the block with a started connection from this Ractor's pool. A
      # reused keep-alive connection the server has since closed is retried
      # once on a fresh one (POST isn't retried by Net::HTTP itself).
      def with_connection(retry_if: nil)
        idle = idle_connections
        reused = true
        http = begin
          idle.pop(true)
        rescue ThreadError
          reused = false
          start_connection
        end

        begin
          # A pooled connection may have been opened by another provider.
          http.read_timeout = @config[:timeout]
          result = yield http
        rescue *RETRYABLE
          http.finish rescue nil # rubocop:disable Style/RescueModifier
          raise unless reused && (retry_if.nil? || retry_if.call)

          reused = false
          http = start_connection
          retry
        rescue StandardError
          http.finish rescue nil # rubocop:disable Style/RescueModifier
          raise
        end

        if idle.size < @config[:max_idle]
          idle << http
        else
          http.finish
        end
        result
      end

      def start_connection
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @config[:open_timeout]
        http.read_timeout = @config[:timeout]
        http.keep_alive_timeout = @config[:keep_alive]
        http.start
      end
    end
  end
end

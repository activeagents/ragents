# frozen_string_literal: true

module Ragents
  # Rails integration for Ragents.
  # Only loaded when Rails is present.
  #
  # This provides:
  # - Configuration via Rails initializers
  # - Generators for creating agents
  # - Integration with Rails logging/instrumentation
  #
  class Railtie < ::Rails::Railtie
    config.ragents = ActiveSupport::OrderedOptions.new

    initializer "ragents.configure" do |app|
      Ragents.configure do |config|
        # Apply Rails config to Ragents
        app.config.ragents.each do |key, value|
          config.public_send("#{key}=", value) if config.respond_to?("#{key}=")
        end
      end
    end

    # Add app/agents to autoload paths
    initializer "ragents.autoload" do |app|
      agents_path = app.root.join("app", "agents")
      if agents_path.exist?
        app.config.autoload_paths << agents_path.to_s
      end
    end

    # Instrument agent runs with ActiveSupport::Notifications
    initializer "ragents.instrumentation" do
      ActiveSupport::Notifications.subscribe("generate.ragents") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        Rails.logger.debug { "[Ragents] Generation completed in #{event.duration.round(2)}ms" }
      end
    end
  end
end

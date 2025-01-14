# frozen_string_literal: true

require "dry/system/container"
require "hanami/configuration"
require "pathname"
require "rack"
require "zeitwerk"
require_relative "constants"
require_relative "slice"
require_relative "slice_name"
require_relative "application/slice_registrar"

module Hanami
  # Hanami application class
  #
  # @since 2.0.0
  class Application
    @_mutex = Mutex.new

    class << self
      def inherited(subclass)
        super

        @_mutex.synchronize do
          subclass.class_eval do
            @_mutex = Mutex.new
            @application_name = SliceName.new(subclass, inflector: -> { subclass.inflector })
            @configuration = Hanami::Configuration.new(application_name: @application_name, env: Hanami.env)
            @autoloader = Zeitwerk::Loader.new
            @container = Class.new(Dry::System::Container)

            @prepared = @booted = false

            extend ClassMethods
          end

          subclass.send :prepare_base_load_path

          Hanami.application = subclass
        end
      end
    end

    # Application class interface
    #
    # rubocop:disable Metrics/ModuleLength
    module ClassMethods
      attr_reader :application_name, :configuration, :autoloader, :container

      alias_method :slice_name, :application_name

      alias_method :config, :configuration

      def application
        self
      end

      def prepare(provider_name = nil)
        container.prepare(provider_name) and return self if provider_name

        return self if prepared?

        configuration.finalize!

        prepare_all

        @prepared = true
        self
      end

      def boot(&block)
        return self if booted?

        prepare

        container.finalize!(&block)

        slices.each(&:boot)

        @booted = true
        self
      end

      def shutdown
        slices.each(&:shutdown)
        container.shutdown!
        self
      end

      def prepared?
        !!@prepared
      end

      def booted?
        !!@booted
      end

      def router
        raise "Application not yet prepared" unless prepared?

        @_mutex.synchronize do
          @_router ||= load_router
        end
      end

      def rack_app
        @rack_app ||= router.to_rack_app
      end

      def slices
        @slices ||= SliceRegistrar.new(self)
      end

      def register_slice(...)
        slices.register(...)
      end

      def register(...)
        container.register(...)
      end

      def register_provider(...)
        container.register_provider(...)
      end

      def start(...)
        container.start(...)
      end

      def key?(...)
        container.key?(...)
      end

      def keys
        container.keys
      end

      def [](...)
        container.[](...)
      end

      def resolve(...)
        container.resolve(...)
      end

      def settings
        @_settings ||= load_settings
      end

      def namespace
        application_name.namespace
      end

      def root
        configuration.root
      end

      def inflector
        configuration.inflector
      end

      private

      def prepare_base_load_path
        base_path = File.join(root, "lib")
        $LOAD_PATH.unshift base_path unless $LOAD_PATH.include?(base_path)
      end

      def prepare_all
        load_settings
        prepare_container_plugins
        prepare_container_base_config
        prepare_container_consts
        container.configured!
        prepare_slices
        # For the application, the autoloader must be prepared after the slices, since
        # they'll be configuring the autoloader with their own dirs
        prepare_autoloader
      end

      def prepare_container_plugins
        container.use(:env, inferrer: -> { Hanami.env })
        container.use(:zeitwerk, loader: autoloader, run_setup: false, eager_load: false)
        container.use(:notifications)
      end

      def prepare_container_base_config
        container.config.root = configuration.root
        container.config.inflector = configuration.inflector

        container.config.provider_dirs = [
          "config/providers",
          Pathname(__dir__).join("application/container/providers").realpath,
        ]
      end

      def prepare_autoload_paths
        # Autoload classes defined in lib/[app_namespace]/
        if root.join("lib", application_name.name).directory?
          autoloader.push_dir(root.join("lib", application_name.name), namespace: namespace)
        end
      end

      def prepare_container_consts
        namespace.const_set :Container, container
        namespace.const_set :Deps, container.injector
      end

      def prepare_slices
        slices.load_slices.each(&:prepare)
        slices.freeze
      end

      def prepare_autoloader
        # Autoload classes defined in lib/[app_namespace]/
        if root.join("lib", application_name.name).directory?
          autoloader.push_dir(root.join("lib", application_name.name), namespace: namespace)
        end

        autoloader.setup
      end

      def load_settings
        require_relative "application/settings"

        prepare_base_load_path
        require File.join(configuration.root, configuration.settings_path)
        settings_class = autodiscover_application_constant(configuration.settings_class_name)
        settings_class.new(configuration.settings_store)
      rescue LoadError
        Settings.new
      end

      def autodiscover_application_constant(constants)
        inflector.constantize([application_name.namespace_name, *constants].join(MODULE_DELIMITER))
      end

      def load_router
        require_relative "application/router"

        Router.new(
          routes: load_routes,
          resolver: router_resolver,
          **configuration.router.options,
        ) do
          use Hanami.application[:rack_monitor]

          Hanami.application.config.for_each_middleware do |m, *args, &block|
            use(m, *args, &block)
          end
        end
      end

      def load_routes
        require_relative "application/routes"

        require File.join(configuration.root, configuration.router.routes_path)
        routes_class = autodiscover_application_constant(configuration.router.routes_class_name)
        routes_class.routes
      rescue LoadError
        proc {}
      end

      def router_resolver
        config.router.resolver.new(
          slices: slices,
          inflector: inflector
        )
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

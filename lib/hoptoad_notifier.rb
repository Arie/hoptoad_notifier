require 'net/http'
require 'net/https'
require 'rubygems'
require 'active_support'

# Plugin for applications to automatically post errors to the Hoptoad of their choice.
module HoptoadNotifier

  IGNORE_DEFAULT = ['ActiveRecord::RecordNotFound',
                    'ActionController::RoutingError',
                    'ActionController::InvalidAuthenticityToken',
                    'CGI::Session::CookieStore::TamperedWithCookie',
                    'ActionController::UnknownAction']

  # Some of these don't exist for Rails 1.2.*, so we have to consider that.
  IGNORE_DEFAULT.map!{|e| eval(e) rescue nil }.compact!
  IGNORE_DEFAULT.freeze

  IGNORE_USER_AGENT_DEFAULT = []

  VERSION = "1.2"
  LOG_PREFIX = "** [Hoptoad] "

  class << self
    attr_accessor :host, :port, :secure, :api_key, :http_open_timeout, :http_read_timeout,
                  :proxy_host, :proxy_port, :proxy_user, :proxy_pass, :verbose, :output

    def backtrace_filters
      @backtrace_filters ||= []
    end

    # Takes a block and adds it to the list of backtrace filters. When the filters
    # run, the block will be handed each line of the backtrace and can modify
    # it as necessary. For example, by default a path matching the RAILS_ROOT
    # constant will be transformed into "[RAILS_ROOT]"
    def filter_backtrace &block
      self.backtrace_filters << block
    end

    # The port on which your Hoptoad server runs.
    def port
      @port || (secure ? 443 : 80)
    end

    # The host to connect to.
    def host
      @host ||= 'hoptoadapp.com'
    end

    # The HTTP open timeout (defaults to 2 seconds).
    def http_open_timeout
      @http_open_timeout ||= 2
    end

    # The HTTP read timeout (defaults to 5 seconds).
    def http_read_timeout
      @http_read_timeout ||= 5
    end

    # Returns the list of errors that are being ignored. The array can be appended to.
    def ignore
      @ignore ||= (HoptoadNotifier::IGNORE_DEFAULT.dup)
      @ignore.flatten!
      @ignore
    end

    # Sets the list of ignored errors to only what is passed in here. This method
    # can be passed a single error or a list of errors.
    def ignore_only=(names)
      @ignore = [names].flatten
    end

    # Returns the list of user agents that are being ignored. The array can be appended to.
    def ignore_user_agent
      @ignore_user_agent ||= (HoptoadNotifier::IGNORE_USER_AGENT_DEFAULT.dup)
      @ignore_user_agent.flatten!
      @ignore_user_agent
    end

    # Sets the list of ignored user agents to only what is passed in here. This method
    # can be passed a single user agent or a list of user agents.
    def ignore_user_agent_only=(names)
      @ignore_user_agent = [names].flatten
    end

    # Returns a list of parameters that should be filtered out of what is sent to Hoptoad.
    # By default, all "password" attributes will have their contents replaced.
    def params_filters
      @params_filters ||= %w(password)
    end

    def environment_filters
      @environment_filters ||= %w()
    end

    def report_ready
      write_verbose_log("Notifier #{VERSION} ready to catch errors")
    end

    def report_environment_info
      write_verbose_log("Environment Info: #{environment_info}")
    end

    def environment_info
      "[Rails: #{::Rails::VERSION::STRING}] [Ruby: #{RUBY_VERSION}] [RailsEnv: #{RAILS_ENV}]"
    end

    def write_verbose_log(message)
      logger.info LOG_PREFIX + message
      STDERR.puts LOG_PREFIX + message
    end

    # Checking for the logger in hopes we can get rid of the ugly syntax someday
    def logger
      defined?(Rails.logger) ? Rails.logger : RAILS_DEFAULT_LOGGER
    end

    # Call this method to modify defaults in your initializers.
    #
    # HoptoadNotifier.configure do |config|
    #   config.api_key = '1234567890abcdef'
    #   config.secure  = false
    # end
    #
    # NOTE: secure connections are not yet supported.
    def configure
      add_default_filters
      yield self
      if defined?(ActionController::Base) && !ActionController::Base.include?(HoptoadNotifier::Catcher)
        ActionController::Base.send(:include, HoptoadNotifier::Catcher)
      end
      report_ready if @verbose
    end

    def protocol #:nodoc:
      secure ? "https" : "http"
    end

    def url #:nodoc:
      URI.parse("#{protocol}://#{host}:#{port}/notices/")
    end

    def default_notice_options #:nodoc:
      {
        :api_key       => HoptoadNotifier.api_key,
        :error_message => 'Notification',
        :backtrace     => caller,
        :request       => {},
        :session       => {},
        :environment   => ENV.to_hash
      }
    end

    # You can send an exception manually using this method, even when you are not in a
    # controller. You can pass an exception or a hash that contains the attributes that
    # would be sent to Hoptoad:
    # * api_key: The API key for this project. The API key is a unique identifier that Hoptoad
    #   uses for identification.
    # * error_message: The error returned by the exception (or the message you want to log).
    # * backtrace: A backtrace, usually obtained with +caller+.
    # * request: The controller's request object.
    # * session: The contents of the user's session.
    # * environment: ENV merged with the contents of the request's environment.
    def notify notice = {}
      Sender.new.notify_hoptoad( notice )
    end

    def add_default_filters
      self.backtrace_filters.clear

      filter_backtrace do |line|
        line.gsub(/#{RAILS_ROOT}/, "[RAILS_ROOT]")
      end

      filter_backtrace do |line|
        line.gsub(/^\.\//, "")
      end

      filter_backtrace do |line|
        if defined?(Gem)
          Gem.path.inject(line) do |line, path|
            line.gsub(/#{path}/, "[GEM_ROOT]")
          end
        end
      end

      filter_backtrace do |line|
        line if line !~ /lib\/#{File.basename(__FILE__)}/
      end
    end
  end

  # Include this module in Controllers in which you want to be notified of errors.
  module Catcher

    def self.included(base) #:nodoc:
      if base.instance_methods.include? 'rescue_action_in_public' and !base.instance_methods.include? 'rescue_action_in_public_without_hoptoad'
        base.send(:alias_method, :rescue_action_in_public_without_hoptoad, :rescue_action_in_public)
        base.send(:alias_method, :rescue_action_in_public, :rescue_action_in_public_with_hoptoad)
      end
    end

    # Overrides the rescue_action method in ActionController::Base, but does not inhibit
    # any custom processing that is defined with Rails 2's exception helpers.
    def rescue_action_in_public_with_hoptoad exception
      notify_hoptoad(exception) unless ignore?(exception) || ignore_user_agent?
      rescue_action_in_public_without_hoptoad(exception)
    end

    # This method should be used for sending manual notifications while you are still
    # inside the controller. Otherwise it works like HoptoadNotifier.notify.
    def notify_hoptoad hash_or_exception
      if public_environment?
        notice = normalize_notice(hash_or_exception)
        notice = clean_notice(notice)
        send_to_hoptoad(:notice => notice)
      end
    end

    alias_method :inform_hoptoad, :notify_hoptoad

    # Returns the default logger or a logger that prints to STDOUT. Necessary for manual
    # notifications outside of controllers.
    def logger
      ActiveRecord::Base.logger
    rescue
      @logger ||= Logger.new(STDERR)
    end

    private

    def public_environment? #nodoc:
      defined?(RAILS_ENV) and !['development', 'test'].include?(RAILS_ENV)
    end

    def ignore?(exception) #:nodoc:
      ignore_these = HoptoadNotifier.ignore.flatten
      ignore_these.include?(exception.class) || ignore_these.include?(exception.class.name)
    end

    def ignore_user_agent? #:nodoc:
      HoptoadNotifier.ignore_user_agent.flatten.any? { |ua| ua === request.user_agent }
    end

    def exception_to_data exception #:nodoc:
      data = {
        :api_key       => HoptoadNotifier.api_key,
        :error_class   => exception.class.name,
        :error_message => "#{exception.class.name}: #{exception.message}",
        :backtrace     => exception.backtrace,
        :environment   => ENV.to_hash
      }

      if self.respond_to? :request
        data[:request] = {
          :params      => request.parameters.to_hash,
          :rails_root  => File.expand_path(RAILS_ROOT),
          :url         => "#{request.protocol}#{request.host}#{request.request_uri}"
        }
        data[:environment].merge!(request.env.to_hash)
      end

      if self.respond_to? :session
        data[:session] = {
          :key         => session.instance_variable_get("@session_id"),
          :data        => session.instance_variable_get("@data")
        }
      end

      data
    end

    def normalize_notice(notice) #:nodoc:
      case notice
      when Hash
        HoptoadNotifier.default_notice_options.merge(notice)
      when Exception
        HoptoadNotifier.default_notice_options.merge(exception_to_data(notice))
      end
    end

    def clean_notice(notice) #:nodoc:
      notice[:backtrace] = clean_hoptoad_backtrace(notice[:backtrace])
      if notice[:request].is_a?(Hash) && notice[:request][:params].is_a?(Hash)
        notice[:request][:params] = filter_parameters(notice[:request][:params]) if respond_to?(:filter_parameters)
        notice[:request][:params] = clean_hoptoad_params(notice[:request][:params])
      end
      if notice[:environment].is_a?(Hash)
        notice[:environment] = filter_parameters(notice[:environment]) if respond_to?(:filter_parameters)
        notice[:environment] = clean_hoptoad_environment(notice[:environment])
      end
      clean_non_serializable_data(notice)
    end

    def log(level, message)
      logger.send level, LOG_PREFIX + message if logger
      HoptoadNotifier.report_environment_info if HoptoadNotifier.verbose
    end

    def send_to_hoptoad data #:nodoc:
      headers = {
        'Content-type' => 'application/x-yaml',
        'Accept' => 'text/xml, application/xml'
      }

      url = HoptoadNotifier.url
      http = Net::HTTP::Proxy(HoptoadNotifier.proxy_host,
                              HoptoadNotifier.proxy_port,
                              HoptoadNotifier.proxy_user,
                              HoptoadNotifier.proxy_pass).new(url.host, url.port)

      http.use_ssl = true
      http.read_timeout = HoptoadNotifier.http_read_timeout
      http.open_timeout = HoptoadNotifier.http_open_timeout
      http.use_ssl = !!HoptoadNotifier.secure 

      response = begin
                   http.post(url.path, stringify_keys(data).to_yaml, headers)
                 rescue TimeoutError => e
                   logger.error "Timeout while contacting the Hoptoad server." if logger
                   nil
                 end

      if response == Net::HTTPSuccess
        log :info, "Success: #{response.class}"
      else
        log :error, "Failure: #{response.class}\n#{response.body if response.respond_to? :body}"
      end
    end

    def clean_hoptoad_backtrace backtrace #:nodoc:
      if backtrace.to_a.size == 1
        backtrace = backtrace.to_a.first.split(/\n\s*/)
      end

      filtered = backtrace.to_a.map do |line|
        HoptoadNotifier.backtrace_filters.inject(line) do |line, proc|
          proc.call(line)
        end
      end

      filtered.compact
    end

    def clean_hoptoad_params params #:nodoc:
      params.each do |k, v|
        params[k] = "[FILTERED]" if HoptoadNotifier.params_filters.any? do |filter|
          k.to_s.match(/#{filter}/)
        end
      end
    end

    def clean_hoptoad_environment env #:nodoc:
      env.each do |k, v|
        env[k] = "[FILTERED]" if HoptoadNotifier.environment_filters.any? do |filter|
          k.to_s.match(/#{filter}/)
        end
      end
    end

    def clean_non_serializable_data(notice) #:nodoc:
      notice.select{|k,v| serializable?(v) }.inject({}) do |h, pair|
        h[pair.first] = pair.last.is_a?(Hash) ? clean_non_serializable_data(pair.last) : pair.last
        h
      end
    end

    def serializable?(value) #:nodoc:
      !(value.is_a?(Module) || value.kind_of?(IO))
    end

    def stringify_keys(hash) #:nodoc:
      hash.inject({}) do |h, pair|
        h[pair.first.to_s] = pair.last.is_a?(Hash) ? stringify_keys(pair.last) : pair.last
        h
      end
    end

  end

  # A dummy class for sending notifications manually outside of a controller.
  class Sender
    def rescue_action_in_public(exception)
    end

    include HoptoadNotifier::Catcher
  end
end

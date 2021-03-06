module Halcyon
  
  # The core of Halcyon on the server side is the Halcyon::Application class
  # which handles dispatching requests and responding with appropriate messages
  # to the client (which can be specified).
  # 
  # Manages shutting down and starting up hooks, routing, dispatching, etc.
  # Also restricts the requests to acceptable clients, defaulting to all.
  class Application
    include Exceptions
    
    autoload :Router, 'halcyon/application/router'
    
    attr_accessor :session
    
    DEFAULT_OPTIONS = {
      :root => Dir.pwd,
      :logging => {
        :type => 'Logger',
        :level => 'info'
      },
      :allow_from => :all
    }.to_mash
    
    # Initializes the app:
    # * runs startup hooks
    # * registers shutdown hooks
    def initialize
      self.logger.info "Starting up..."
      
      self.hooks[:startup].call(Halcyon.config, Halcyon.logger) if self.hooks[:startup]
      
      # clean after ourselves and get prepared to start serving things
      self.logger.debug "Starting GC."
      GC.start
      
      self.logger.info "Started. PID is #{$$}"
      
      at_exit do
        self.logger.info "Shutting down #{$$}."
        self.hooks[:shutdown].call(Halcyon.config, Halcyon.logger) if self.hooks[:shutdown]
        self.logger.info "Done."
      end
    end
    
    # Sets up the request and response objects for use in the controllers and
    # dispatches requests. Renders response data as JSON for response.
    #   +env+ the request environment details
    # 
    # The internal router (which inherits from the Merb router) is sent the
    # request to pass back the route for the dispatcher to call. This route is
    # stored in <tt>env['halcyon.route']</tt> (as per the Rack spec).
    # 
    # Configs
    #   <tt>Halcyon.config[:allow_from]</tt> #=> (default) <tt>:all</tt>
    #     :all              => does not restrict requests from any User-Agent
    #     :local            => restricts requests to only local requests (from
    #                          localhost, 0.0.0.0, 127.0.0.1)
    #     :halcyon_clients  => restricts to only Halcyon clients (identified by
    #                          User-Agent)
    # 
    # Exceptions
    #   If a request raises an exception that inherits from
    #   <tt>Halcyon::Exceptions::Base</tt> (<tt>NotFound</tt>, etc), then the
    #   response is sent with this information.
    #   If a request raises any other kind of <tt>Exception</tt>, it is logged
    #   as an error and a <tt>500 Internal Server Error</tt> is returned.
    # 
    # Returns [Fixnum:status, {String:header => String:value}, [String:body].to_json]
    def call(env)
      timing = {:started => Time.now}
      
      request = Rack::Request.new(env)
      response = Rack::Response.new
      
      response['Content-Type'] = "application/json"
      response['User-Agent'] = "JSON/#{JSON::VERSION} Compatible (en-US) Halcyon::Application/#{Halcyon.version}"
      
      begin
        acceptable_request!(env)
        
        env['halcyon.route'] = Router.route(request)
        result = dispatch(env)
      rescue Exceptions::Base => e
        result = {:status => e.status, :body => e.body}
        self.logger.info e.message
      rescue Exception => e
        result = {:status => 500, :body => 'Internal Server Error'}
        self.logger.error "#{e.message}\n\t" << e.backtrace.join("\n\t")
      end
      
      response.status = result[:status]
      response.write result.to_json
      
      timing[:finished] = Time.now
      timing[:total] = (((timing[:finished] - timing[:started])*1e4).round.to_f/1e4)
      timing[:per_sec] = (((1.0/(timing[:total]))*1e2).round.to_f/1e2)
      
      self.logger.info "[#{response.status}] #{URI.parse(env['REQUEST_URI'] || env['PATH_INFO']).path} (#{timing[:total]}s;#{timing[:per_sec]}req/s)"
      # self.logger << "Session ID: #{self.session.id}\n" # TODO: Implement session
      self.logger << "Params: #{request.params.merge(env['halcyon.route']).inspect}\n\n"
      
      response.finish
    end
    
    # Dispatches the controller and action according the routed request.
    #   +env+ the request environment details, including "halcyon.route"
    # 
    # If no <tt>:controller</tt> is specified, the default <tt>Application</tt>
    # controller is dispatched to.
    # 
    # Once the controller is selected and instantiated, the action is called,
    # defaulting to <tt>:default</tt> if no action is provided.
    # 
    # If the action called is not defined, a <tt>404 Not Found</tt> exception
    # will be raised. This will be sent to the client as such, or handled by
    # the Rack application container, such as the Rack Cascade middleware to
    # failover to another application (such as Merb or Rails).
    # 
    # Refer to Halcyon::Application::Router for more details on defining routes
    # and for where to get further documentation.
    # 
    # Returns (String|Array|Hash):body
    def dispatch(env)
      route = env['halcyon.route']
      # make sure that the right controller/action is called based on the route
      controller = case route[:controller]
      when NilClass
        # default to the Application controller
        ::Application.new(env)
      when String
        # pulled from URL, so camelize (from merb/core_ext) and symbolize first
        Object.const_get(route[:controller].camel_case.to_sym).new(env)
      end
      
      begin
        controller.send((route[:action] || 'default').to_sym)
      rescue NoMethodError => e
        raise NotFound.new
      end
    end
    
    # Filters unacceptable requests depending on the configuration of the
    # <tt>:allow_from</tt> option.
    # 
    # This method is not directly called by the user, instead being called
    # in the #call method.
    # 
    # Acceptable values include:
    #   <tt>:all</tt>:: allow every request to go through
    #   <tt>:halcyon_clients</tt>:: only allow Halcyon clients
    #   <tt>:local</tt>:: do not allow for requests from an outside host
    # 
    # Raises Forbidden
    def acceptable_request!(env)
      case Halcyon.config[:allow_from].to_sym
      when :all
        # allow every request to go through
      when :halcyon_clients
        # only allow Halcyon clients
        raise Forbidden.new unless env['USER_AGENT'] =~ /JSON\/1\.1\.\d+ Compatible \(en-US\) Halcyon::Client\(\d+\.\d+\.\d+\)/
      when :local
        # do not allow for requests from an outside host
        raise Forbidden.new unless ['localhost', '127.0.0.1', '0.0.0.0'].member? env["REMOTE_ADDR"]
      else
        logger.warn "Unrecognized allow_from configuration value (#{Halcyon.config[:allow_from].to_s}); use all, halcyon_clients, or local. Allowing all requests."
      end
    end
    
    def logger
      Halcyon.logger
    end
    
    def hooks
      self.class.hooks
    end
    
    class << self
      
      attr_accessor :hooks
      
      def hooks
        @hooks ||= {}
      end
      
      def logger
        Halcyon.logger
      end
      
      # Defines routes for the application.
      # 
      # Refer to Halcyon::Application::Router for documentation and resources.
      def route
        if block_given?
          Router.prepare do |router|
            Router.default_to yield(router) || {:controller => 'application', :action => 'not_found'}
          end
        end
      end
      
      # Sets the startup hook to the proc.
      # 
      # Use this to initialize application-wide resources, such as database
      # connections.
      # 
      # Use initializers where possible.
      def startup &hook
        self.hooks[:startup] = hook
      end
      
      # Sets the shutdown hook to the proc.
      # 
      # Close any resources opened in the +startup+ hook.
      def shutdown &hook
        self.hooks[:shutdown] = hook
      end
      
    end
    
  end
  
end

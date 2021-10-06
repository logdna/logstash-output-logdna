# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"
require "zlib"
require "date"

class LogStash::Outputs::LogDNA < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  concurrency :shared

  attr_accessor :is_batch

  RETRYABLE_MANTICORE_EXCEPTIONS = [
    ::Manticore::Timeout,
    ::Manticore::SocketException,
    ::Manticore::ClientProtocolException,
    ::Manticore::ResolutionFailure,
    ::Manticore::SocketTimeout
  ]

  # This output lets you send events to LogDNA via it's Ingest API
  #
  # This output will execute up to 'pool_max' requests in parallel for performance.
  # Consider this when tuning this plugin for performance.
  #
  # Additionally, note that when parallel execution is used strict ordering of events is not
  # guaranteed!
  #
  # Beware, this gem does not yet support codecs. Please use the 'format' option for now.

  config_name "logdna"

  # Your LogDNA API key.  Required
  config :api_key, :validate => :string, :required => :true

  # The default app name when not present in the log event
  config :app, :validate => :string, :default => ""

  # The default environment when not present in the log event
  config :env, :validate => :string, :default => ""

  # The default hostname when not present in the log event.
  #    URL required BUT Logstash uses host in event so if not
  #    defined, using that
  config :hostname, :validate => :string, :default => ""

  # The default IP when not present in the log event
  config :ip, :validate => :string, :default => ""

  # The default level when not present in the log event
  config :level, :validate => :string, :default => ""

  # The default network mac address of the host computer
  config :mac, :validate => :string, :default => ""

  # Recommended: The source unix timestamp in milliseconds at the time of the request. Used to calculate time drift.
  config :now, :validate => :string, :default => ""

  # Tags used to dynamically group logs.  For instance: dev,web
  config :tags, :validate => :string, :default => ""

  # LogDNA URL to send logs to.
  config :base_url, :validate => :string, :default => "https://logs.logdna.com/logs/ingest"

  # Custom headers to use
  # format is `headers => ["X-My-Header", "%{host}"]`
  config :headers, :validate => :hash, :default => {}

  # Content type
  #
  # If not specified, this defaults to the following:
  #
  # * if format is "json", "application/json"
  config :content_type, :validate => :string

  # Set this to false if you don't want this output to retry failed requests
  config :retry_failed, :validate => :boolean, :default => true

  # If encountered as response codes this plugin will retry these requests
  config :retryable_codes, :validate => :number, :list => true, :default => [429, 500, 502, 503, 504]

  # If you would like to consider some non-2xx codes to be successes
  # enumerate them here. Responses returning these codes will be considered successes
  config :ignorable_codes, :validate => :number, :list => true

  # This lets you choose the structure and parts of the event that are sent.
  #
  #
  # For example:
  # [source,ruby]
  #    mapping => {"foo" => "%{host}"
  #               "bar" => "%{type}"}
  config :mapping, :validate => :hash

  # Set the format of the http body.
  #
  # If message, then the body will be the result of formatting the event according to message
  # If json_batch, will be sent as a json batch of lines
  # Otherwise, the event is sent as json.
  config :format, :validate => ["plain/text", "json", "json_batch", "message"], :default => "plain/text"

  config :message, :validate => :string

  attr_accessor :http_method

  def getFromHost(host,key)
    ret = ""
    begin
      # Get base
      tmp_base = host[key]
      # Check if Array
      tmp_base = tmp_base.kind_of?(Array) ? tmp_base[0] : tmp_base
      # Check if String
      ret = tmp_base.kind_of?(String) ? tmp_base : ret
    rescue
    end
    return ret
  end

  def genLogDNAUrl(event)
    ingestion_key = event.get('[@metadata][logdna][api_key]') ? event.get('[@metadata][logdna][api_key]') : @api_key
    tmp_url = "#{@base_url}?apikey=#{ingestion_key}"

    # Note that we will try and grab these from the event.
    #    if they appear as first level attributes, they will
    #    be added
    # Also, hostname will pull from host in the event as well before the config
    # DEPENDING ON THE INPUT, THIS ALL MAY NEED TO BE TWEAKED WITH ADDITIONAL LOGICS
    @logger.debug("EVENT: #{event}")

    event_hostname = event.get('[hostname]') ? event.get('[hostname]') : ""
    event_host = event.get('[host]') ? event.get('[host]') : ""
    event_mac = event.get('[mac]') ? event.get("[mac]") : ""
    event_ip = event.get('[ip]') ? event.get("[ip]") : ""
    event_now = event.get('[now]') ? event.get("[now]") : ""
    event_timestamp = event.get('[timestamp]') ? event.get('[timestamp]') : ""
    event_Atimestamp = event.get('[@timestamp]') ? event.get('[@timestamp]') : ""
    event_tags = event.get('[tags]') ? event.get("[tags]") : ""

    event_host_hostname = getFromHost(event_host,'hostname')
    event_host_mac = getFromHost(event_host,'mac')
    event_host_ip = getFromHost(event_host,'ip')
    if event_hostname.empty?
      event_hostname = event_host_hostname.empty? ? event_hostname : event_host_hostname
    end
    if event_mac.empty?
      event_mac = event_host_mac.empty? ? event_mac : event_host_mac
    end
    if event_ip.empty?
      event_ip = event_host_ip.empty? ? event_ip : event_host_ip
    end

    # mutate a list of tags to TAG1,TAG2,..
    if event_tags.kind_of?(Array)
      event_tags = event_tags.join(",") # assumes no "," in the tags themselves
    end
    if !event_tags.empty? && !@tags.empty?
      event_tags = @tags + "," + event_tags
    end

    @logger.debug("@tags: #{@tags}")

    @logger.debug("hostname: #{event_hostname}")
    @logger.debug("host: #{event_host}")
    @logger.debug("mac: #{event_mac}")
    @logger.debug("ip: #{event_ip}")
    @logger.debug("now: #{event_now}")
    @logger.debug("timestamp: #{event_timestamp}")
    @logger.debug("@timestamp: #{event_Atimestamp}")
    @logger.debug("tags: #{event_tags}")

    # REQUIRED
    if !event_hostname.empty?
      @logger.debug("event.hostname: #{event_hostname}")
      tmp_url += "&hostname=#{event_hostname}"
    elsif !event_host.empty?
      @logger.debug("event.host: #{event_host}")
      tmp_url += "&hostname=#{event_host}"
    elsif !@hostname.empty?
      @logger.debug("config.hostname: #{@hostname}")
      tmp_url += "&hostname=#{@hostname}"
    else
      raise '"hostname" must be defined and must not be empty in either the config or event.  "host" within event works too.'
    end

    if !event_mac.empty?
      tmp_url += "&mac=#{event_mac}"
    elsif !@mac.empty?
      tmp_url += "&mac=#{@mac}"
    end

    if !event_ip.empty?
      tmp_url += "&ip=#{event_ip}"
    elsif !@ip.empty?
      tmp_url += "&ip=#{@ip}"
    end

    # TODO: validate log timestamp logic.  Unsure what the @timestamp in logstash is
    #  Also, this is fragile as hell.  NEEDS WORK
    if !event_now.empty?
      tmp_url += "&now=#{event_now}"
    elsif !event_timestamp.empty?
      tmp_url += "&now=#{event_timestamp}"
    elsif !defined?(event_Atimestamp)
      tmp_ts_string = event_Atimestamp.to_i
      tmp_url += "&now=#{tmp_ts_string}"
    elsif !@now.empty?
      tmp_url += "&now=#{@now}"
    #else
    #  tmp_url += "&now=$(date +%s)"
    end

    if !event_tags.empty?
      tmp_url += "&tags=#{event_tags}"
    elsif !@tags.empty?
      tmp_url += "&tags=#{@tags}"
    end

    return tmp_url
  end

  def register
    @http_method = "post".to_sym

    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }

    @requests = Array.new

    if @content_type.nil?
      case @format
        when "plain/text" ; @content_type = "text/plain;charset=UTF-8"
        when "json" ; @content_type = "application/json" # One JSON log is better sent as text/plain
        when "json_batch" ; @content_type = "application/json" # Requires fornatting to fit {"lines":[{"line":...}]}
        when "message" ; @content_type = "text/plain;charset=UTF-8"
      end
    end

    @is_batch = @format == "json_batch"

    @headers["Content-Type"] = @content_type

    validate_format!

    # Run named Timer as daemon thread
    @timer = java.util.Timer.new("LogDNA Output #{self.params['id']}", true)
  end # def register

  def multi_receive(events)
    return if events.empty?
    send_events(events)
  end

  class RetryTimerTask < java.util.TimerTask
    def initialize(pending, event, attempt)
      @pending = pending
      @event = event
      @attempt = attempt
      super()
    end

    def run
      @pending << [@event, @attempt]
    end
  end

  def log_retryable_response(response)
    if (response.code == 429)
      @logger.debug? && @logger.debug("Encountered a 429 response, will retry. This is not serious, just flow control via HTTP")
    else
      @logger.warn("Encountered a retryable HTTP request in LogDNA output, will retry", :code => response.code, :body => response.body)
    end
  end

  def log_error_response(response, url, event)
    log_failure(
              "Encountered non-2xx HTTP code #{response.code}",
              :response_code => response.code,
              :context => response.context,
              :headers => response.headers,
              :body => response.body(),
              :message => response.message(),
              :time_retried => response.times_retried(),
              :request => response.request,
              :url => url,
              :event => event
            )
  end

  def send_events(events)
    successes = java.util.concurrent.atomic.AtomicInteger.new(0)
    failures  = java.util.concurrent.atomic.AtomicInteger.new(0)
    retries = java.util.concurrent.atomic.AtomicInteger.new(0)
    event_count = @is_batch ? 1 : events.size

    pending = Queue.new
    if @is_batch
      pending << [events, 0]
    else
      events.each {|e| pending << [e, 0]}
    end

    while popped = pending.pop
      break if popped == :done

      event, attempt = popped

      action, event, attempt = send_event(event, attempt)
      begin
        action = :failure if action == :retry && !@retry_failed

        case action
        when :success
          successes.incrementAndGet
        when :retry
          retries.incrementAndGet

          next_attempt = attempt+1
          sleep_for = sleep_for_attempt(next_attempt)
          @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
          timer_task = RetryTimerTask.new(pending, event, next_attempt)
          @timer.schedule(timer_task, sleep_for*1000)
        when :failure
          failures.incrementAndGet
        else
          raise "Unknown action #{action}"
        end

        if action == :success || action == :failure
          if successes.get+failures.get == event_count
            pending << :done
          end
        end
      rescue => e
        # This should never happen unless there's a flat out bug in the code
        @logger.error("Error sending HTTP Request",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
        failures.incrementAndGet
        raise e
      end
    end
  rescue => e
    @logger.error("Error in LogDNA output loop",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
    raise e
  end

  def sleep_for_attempt(attempt)
    sleep_for = attempt**2
    sleep_for = sleep_for <= 60 ? sleep_for : 60
    (sleep_for/2) + (rand(0..sleep_for)/2)
  end

  def send_event(event, attempt)
    body = event_body(event)

    # create the url to use
    tmp_url = genLogDNAUrl(event)
    #tmp_url = "https://logs.logdna.com/logs/ingest"
    headers = @is_batch ? @headers : event_headers(event)

    @logger.debug("Utilized url: #{tmp_url}")
    @logger.debug("Utilized header: #{headers}")
    @logger.debug("Utilized body: #{body}")

    # Create an async request
    # client is manticore
    response = client.send(@http_method, tmp_url, :body => body, :headers => headers).call

    if !response_success?(response)
      if retryable_response?(response)
        log_retryable_response(response)
        return :retry, event, attempt
      else
        log_error_response(response, tmp_url, event)
        return :failure, event, attempt
      end
    else
      return :success, event, attempt
    end

  rescue => exception
    will_retry = retryable_exception?(exception)
    log_params = {
      :url => tmp_url,
      :method => @http_method,
      :message => exception.message,
      :class => exception.class.name,
      :will_retry => will_retry
    }
    if @logger.debug?
      # backtraces are big
      log_params[:backtrace] = exception.backtrace
      # headers can have sensitive data
      log_params[:headers] = headers
      # body can be big and may have sensitive data
      log_params[:body] = body
    end
    log_failure("Could not fetch URL", log_params)

    if will_retry
      return :retry, event, attempt
    else
      return :failure, event, attempt
    end
  end

  def close
    @timer.cancel
    client.close
  end

  private

  def response_success?(response)
    code = response.code
    return true if @ignorable_codes && @ignorable_codes.include?(code)
    return code >= 200 && code <= 299
  end

  def retryable_response?(response)
    @retryable_codes && @retryable_codes.include?(response.code)
  end

  def retryable_exception?(exception)
    RETRYABLE_MANTICORE_EXCEPTIONS.any? {|me| exception.is_a?(me) }
  end

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    @logger.error("[LogDNA Output Failure] #{message}", opts)
  end

  # Format the HTTP body
  def event_body(event)
    # TODO: Create an HTTP post data codec, use that here

    # LogDNA Ingest API plain/text formatting assumptions
    #   1. "app" need be "_app" to be parsed properly.  If "app"
    #      is found and "_app" isn't defined, add additional
    #      "_app" field (to event)
    #   2. "env" need be "_env" to be parsed properly.  If "env"
    #      is found and "_env" isn't defined, add additional
    #      "_env field (to event)
    #   3.
    event_app = event.get('[app]') ? event.get('[app]') : ""
    event__app = event.get('[_app]') ? event.get('[_app]') : ""
    event_env = event.get('[env]') ? event.get('[env]') : ""
    event__env = event.get('[_env]') ? event.get('[_env]') : ""

    event_level = event.get('[level]') ? event.get('[level]') : ""

    # Mutate according to rules and add level from config (others come from url)
    if !event_app.empty? && event__app.empty?
      event.set("_app", event_app)
    elsif !@app.empty?
      event.set("_app", @app)
    end

    if !event_env.empty? && event__env.empty?
      event.set("_env", event_env)
    elsif !@env.empty?
      event.set("_env", @env)
    end

    if event_level.empty? && !@level.empty?
      event.set("level",@level)
    end

    #event_timestamp = "" #event.get('[@timestamp]') ? event.get('[@timestamp]') : ""
    event_message = event.get('[message]') ? event.get('[message]') : ""

    # Actually format packet
    if @format == "plain/text"
      LogStash::Json.dump(map_event(event))
    elsif @format == "json"
      #out = { "lines" => [ { "line"=>event_message, "timestamp"=>event_timestamp, "app"=>event_app, "env"=>event_env, "level"=>event_level, "meta"=>map_event(event) } ] }
      out = { "lines" => [ { "line"=>event_message, "app"=>event_app, "env"=>event_env, "level"=>event_level, "meta"=>map_event(event) } ] }
      LogStash::Json.dump(out)
    elsif @format == "message"
      event.sprintf(@message)
    elsif @format == "json_batch"
      #not working yet
      #LogStash::Json.dump({ "lines"=>event.map {|e| {"line"=>map_event(e)} }})
      LogStash::Json.dump(map_event(event))
    end
  end

  def convert_mapping(mapping, event)
    if mapping.is_a?(Hash)
      mapping.reduce({}) do |acc, kv|
        k, v = kv
        acc[k] = convert_mapping(v, event)
        acc
      end
    elsif mapping.is_a?(Array)
      mapping.map { |elem| convert_mapping(elem, event) }
    else
      event.sprintf(mapping)
    end
  end

  def map_event(event)
    if @mapping
      convert_mapping(@mapping, event)
    else
      event.to_hash
    end
  end

  def event_headers(event)
    custom_headers(event) || {}
  end

  def custom_headers(event)
    return nil unless @headers

    @headers.reduce({}) do |acc,kv|
      k,v = kv
      acc[k] = event.sprintf(v)
      acc
    end
  end


  def validate_format!
    if @format == "message"
      if @message.nil?
        raise "message must be set if message format is used"
      end

      if @content_type.nil?
        raise "content_type must be set if message format is used"
      end

      unless @mapping.nil?
        @logger.warn "mapping is not supported and will be ignored if message format is used"
      end
    end
  end
end

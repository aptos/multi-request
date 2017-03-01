require 'em-http-request'
require 'faraday'
require 'faraday_middleware'
require 'resolv'
require 'resolv-replace'
require 'csv'
require 'benchmark'
require 'pry'

class Checks

  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/48.0.2564.103 Safari/537.36'
  GOOGLE_BOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  BING_BOT = "Mozilla/5.0 (compatible; Bingbot/2.0; +http://www.bing.com/bingbot.htm)"

  attr_accessor :stats, :errors, :urls
  def initialize
    @urls = CSV.read('website_urls.csv')
    @errors = {}
    @stats = {}
    @batch_size = 1000
  end

  def fast_checks
    request_options = {
      redirects: 3,
      head: {'user-agent' => GOOGLE_BOT}
    }
    connection_options = {
      :connect_timeout => 5,
      :inactivity_timeout => 10
    }

    EventMachine.run do
      multi = EventMachine::MultiRequest.new

      urls.slice(0..@batch_size).each do |row|
        multi.add row[0], EventMachine::HttpRequest.new(row[2], connection_options).head(request_options) if row[2]
      end

      multi.callback do
        @stats[:pass] = multi.responses[:callback].count
        @stats[:fail] = multi.responses[:errback].count
        @errors = multi.responses[:errback]
        EventMachine.stop
      end
    end
  end

  def retry_errors
    @errors.each do |k,v|
      # next if v.error.to_s.match('unable to resolve address')
      uri = v.conn.uri
      begin
        response = client(uri).get
        if response.status < 299
          @errors.delete k
        end
      rescue
        # retry failed
      end
    end
  end

  def resolv_ipv4
    EM.run do
      urls.slice(0..@batch_size).each do |row|
        addr = URI.parse row[1]
        begin
          d = EM::DNS::Resolver.resolve addr.host.to_s
          d.errback {|r| puts "error: #{r} : #{addr.host}"}
          d.callback { |r|
            addr.host = r.first
            row << addr.to_s
          }
        rescue StandardError => e
          puts "Error in resolver for: #{addr.inspect}"
        end
      end

      # timeout all dns calls at X seconds
      EM.add_timer(20) do
        EM.stop
      end
    end
  end

  def client(url)
    Faraday.new(url) do |faraday|
      faraday.options.timeout = 15
      faraday.use FaradayMiddleware::FollowRedirects, standards_compliant: true
      faraday.adapter Faraday.default_adapter
    end
  end
end

c = Checks.new
time = Benchmark.realtime do
  c.resolv_ipv4
end
puts "\n\n*** Resolv complete in #{time} s\n"

time = Benchmark.realtime do
  c.fast_checks
end
puts "\n\n*** Fastchecks complete in #{time} seconds"
puts c.stats
c.errors.each{|k,v| puts "#{k}: #{v.error} : #{v.conn.uri}" }

# puts "\n\n*** Retries\n"
# time = Benchmark.realtime do
#   c.retry_errors
# end
# puts "\n\n*** Retires complete in #{time} seconds"
# c.errors.each{|k,v| puts "#{k}: #{v.error} : #{v.conn.uri}"}

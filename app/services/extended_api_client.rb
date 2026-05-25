require "net/http"

class ExtendedApiClient
  def initialize(env: ENV, http_get: nil)
    @env = env
    @http_get = http_get || method(:http_get)
  end

  def configured?
    config_blockers.empty?
  end

  def config_blockers
    HedgeVenues::Extended::REQUIRED_CONFIG.filter_map do |key, message|
      message if @env[key].blank?
    end
  end

  def account_info
    get("/user/account/info")
  end

  def balance
    get("/user/balance")
  end

  def positions(market:)
    get("/user/positions", market: market)
  end

  def open_orders(market:)
    get("/user/orders", market: market)
  end

  def market(market:)
    get("/info/markets", market: market)
  end

  def market_stats(market:)
    get("/info/markets/#{URI.encode_www_form_component(market)}/stats")
  end

  private

  def get(path, params = {})
    raise ArgumentError, config_blockers.join(", ") unless configured?

    uri = URI.join(api_base_url, path.delete_prefix("/"))
    uri.query = URI.encode_www_form(params) if params.present?
    response = @http_get.call(uri, headers)
    JSON.parse(response.body)
  end

  def http_get(uri, headers)
    request = Net::HTTP::Get.new(uri)
    headers.each { |key, value| request[key] = value }
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end
  end

  def headers
    {
      "Accept" => "application/json",
      "X-Api-Key" => @env.fetch("EXTENDED_API_KEY", "")
    }
  end

  def api_base_url
    @env.fetch("EXTENDED_API_BASE_URL").end_with?("/") ? @env.fetch("EXTENDED_API_BASE_URL") : "#{@env.fetch('EXTENDED_API_BASE_URL')}/"
  end
end

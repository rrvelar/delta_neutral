require "net/http"

class ExtendedStarkSignerClient
  def initialize(env: ENV, http_get: nil)
    @env = env
    @http_get = http_get || method(:http_get)
  end

  def health
    return { ok: false, reason: "EXTENDED_SIGNER_URL missing" } if @env["EXTENDED_SIGNER_URL"].blank?

    response = @http_get.call(URI.join(signer_url, "health"))
    JSON.parse(response.body).with_indifferent_access
  rescue => e
    { ok: false, reason: "#{e.class}: #{e.message}" }
  end

  def supports_extended_order_signing?
    payload = health
    !!(ActiveModel::Type::Boolean.new.cast(payload[:ok]) &&
      Array.wrap(payload[:supported_exchanges]).include?("Extended") &&
      Array.wrap(payload[:supported_actions]).include?("sign_extended_order") &&
      verified_algorithm? &&
      signing_enabled?)
  end

  def verified_algorithm?
    ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
  end

  def signing_enabled?
    ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
  end

  private

  def http_get(uri)
    Net::HTTP.get_response(uri)
  end

  def signer_url
    @env.fetch("EXTENDED_SIGNER_URL").end_with?("/") ? @env.fetch("EXTENDED_SIGNER_URL") : "#{@env.fetch('EXTENDED_SIGNER_URL')}/"
  end
end

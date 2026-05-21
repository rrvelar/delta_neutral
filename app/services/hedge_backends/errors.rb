module HedgeBackends
  module Errors
  end

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class NetworkError < Error; end
  class ExchangeRejectedOrder < Error; end
  class UnknownOrderState < Error; end
  class ReadbackUnavailable < Error; end
  class PrecisionError < Error; end
  class RiskLimitError < Error; end
  class UnsupportedOperation < Error; end
  class ParseError < Error; end
end

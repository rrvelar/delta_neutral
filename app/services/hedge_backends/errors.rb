module HedgeBackends
  module Errors
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

  Error = Errors::Error unless const_defined?(:Error, false)
  ConfigurationError = Errors::ConfigurationError unless const_defined?(:ConfigurationError, false)
  AuthenticationError = Errors::AuthenticationError unless const_defined?(:AuthenticationError, false)
  RateLimitError = Errors::RateLimitError unless const_defined?(:RateLimitError, false)
  NetworkError = Errors::NetworkError unless const_defined?(:NetworkError, false)
  ExchangeRejectedOrder = Errors::ExchangeRejectedOrder unless const_defined?(:ExchangeRejectedOrder, false)
  UnknownOrderState = Errors::UnknownOrderState unless const_defined?(:UnknownOrderState, false)
  ReadbackUnavailable = Errors::ReadbackUnavailable unless const_defined?(:ReadbackUnavailable, false)
  PrecisionError = Errors::PrecisionError unless const_defined?(:PrecisionError, false)
  RiskLimitError = Errors::RiskLimitError unless const_defined?(:RiskLimitError, false)
  UnsupportedOperation = Errors::UnsupportedOperation unless const_defined?(:UnsupportedOperation, false)
  ParseError = Errors::ParseError unless const_defined?(:ParseError, false)
end

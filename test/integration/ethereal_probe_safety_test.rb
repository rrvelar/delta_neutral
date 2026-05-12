require "test_helper"

class EtherealProbeSafetyTest < ActiveSupport::TestCase
  DANGEROUS_METHODS = %i[
    open_short close_short rebalance_short place_order cancel_order set_leverage
    ensure_leverage transfer withdraw deposit sign_order sign execute
  ].freeze

  DANGEROUS_ENDPOINT_FRAGMENTS = %w[
    /orders /order /cancel /withdraw /transfer /leverage /signer /sign /execute /trade
  ].freeze

  FORBIDDEN_ENV_VARS = %w[
    ETHEREAL_PRIVATE_KEY ETHEREAL_SIGNING_KEY ETHEREAL_TRADING_KEY
    ETHEREAL_ORDER_ENABLED ETHEREAL_CLOSE_ENABLED ETHEREAL_LIVE_APPROVED
  ].freeze

  test "production runtime files do not reference Ethereal" do
    production_files = %w[
      app/jobs/hedge_sync_job.rb
      app/services/aerodrome_production_live_runner.rb
      app/services/aerodrome_live_emergency_close.rb
      app/services/hyperliquid_service.rb
    ]

    production_files.each do |path|
      assert_no_match(/Ethereal|ETHEREAL|HedgeBackends/, Rails.root.join(path).read, "#{path} must not route production to Ethereal")
    end
  end

  test "production runner tasks do not mention Ethereal" do
    aerodrome_tasks = Rails.root.join("lib/tasks/aerodrome.rake").read

    assert_no_match(/Ethereal|ETHEREAL/, aerodrome_tasks)
  end

  test "ethereal read only probe does not define dangerous methods" do
    defined_methods = HedgeBackends::EtherealReadOnlyProbe.public_instance_methods(false)

    assert_empty DANGEROUS_METHODS & defined_methods
  end

  test "ethereal service code does not call dangerous endpoint fragments" do
    service_files = Rails.root.join("app/services/hedge_backends").children.select { |path| path.extname == ".rb" }
    code = service_files.reject { |path| path.basename.to_s == "ethereal_endpoint_policy.rb" }.map(&:read).join("\n")

    DANGEROUS_ENDPOINT_FRAGMENTS.each do |fragment|
      assert_no_match(/["']#{Regexp.escape(fragment)}/, code, "read-only Ethereal services must not call #{fragment}")
    end
  end

  test "ethereal env examples do not include dangerous env vars" do
    env_example = Rails.root.join(".env.example").read

    FORBIDDEN_ENV_VARS.each do |env_var|
      assert_no_match(/^#{env_var}=/, env_example)
    end
  end

  test "webmock blocks external network in tests" do
    assert_not WebMock.net_connect_allowed?("https://api.ethereal.trade")
    assert_not WebMock.net_connect_allowed?("https://api.etherealtest.net")
  end

  test "endpoint policy classifies dangerous endpoints as dangerous" do
    assert_equal :dangerous_execution, HedgeBackends::EtherealEndpointPolicy.category("POST /v1/order")
    assert_equal :dangerous_execution, HedgeBackends::EtherealEndpointPolicy.category("POST /v1/order/cancel")
    assert_equal :dangerous_execution, HedgeBackends::EtherealEndpointPolicy.category("POST /v1/linked-signer/link")
    assert_equal :dangerous_execution, HedgeBackends::EtherealEndpointPolicy.category("POST /v1/token/{id}/withdraw")
  end

  test "endpoint policy allows only read-only probe endpoints used by probe" do
    probe_source = Rails.root.join("app/services/hedge_backends/ethereal_read_only_probe.rb").read
    endpoints = probe_source.scan(%r{"/v1/[^"]+"}).map { |match| "GET #{match.delete_prefix('"').delete_suffix('"')}" }.uniq

    endpoints.each do |endpoint|
      assert HedgeBackends::EtherealEndpointPolicy.read_only_probe_endpoint?(endpoint), "#{endpoint} is not allowed for the read-only probe"
      assert_not HedgeBackends::EtherealEndpointPolicy.dangerous?(endpoint)
    end
  end
end

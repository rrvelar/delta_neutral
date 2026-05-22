module HedgeBackends
  class EtherealSafetyCheck
    BANNER = "ETHEREAL READ-ONLY SAFETY CHECK - STATIC ONLY".freeze
    DANGEROUS_METHODS = %i[
      open_short close_short rebalance_short place_order cancel_order set_leverage
      ensure_leverage transfer withdraw deposit sign_order sign execute
    ].freeze
    FORBIDDEN_ENV_VARS = %w[
      ETHEREAL_PRIVATE_KEY ETHEREAL_SIGNING_KEY ETHEREAL_TRADING_KEY
      ETHEREAL_ORDER_ENABLED ETHEREAL_CLOSE_ENABLED ETHEREAL_LIVE_APPROVED
    ].freeze
    PRODUCTION_FILES = %w[
      app/jobs/hedge_sync_job.rb
      app/services/hyperliquid_service.rb
      app/services/aerodrome_production_live_runner.rb
      app/services/aerodrome_live_emergency_close.rb
    ].freeze
    DANGEROUS_POLICY_ENDPOINTS = [
      "POST /v1/order",
      "POST /v1/order/cancel",
      "POST /v1/token/{id}/withdraw",
      "POST /v1/linked-signer/link"
    ].freeze

    def report
      checks = [
        dangerous_methods_absent,
        forbidden_env_vars_absent,
        production_files_do_not_reference_ethereal,
        no_schema_or_migration_diff,
        no_tracked_observations,
        dangerous_endpoints_classified,
        observation_summary_live_adapter_false
      ]
      blockers = checks.select { |check| check.fetch(:status) == "fail" }.map { |check| check.fetch(:message) }

      {
        safety_banner: BANNER,
        network_calls: false,
        database_write: false,
        orders_enabled: false,
        close_enabled: false,
        signing_enabled: false,
        hyperliquid_execution: false,
        production_wiring: false,
        checks: checks,
        blockers: blockers,
        warnings: [],
        status: blockers.empty? ? "PASS" : "BLOCKED"
      }
    end

    private

    def dangerous_methods_absent
      found = DANGEROUS_METHODS & EtherealReadOnlyProbe.public_instance_methods(false)
      check("dangerous methods absent", found.empty?, found.join(", "))
    end

    def forbidden_env_vars_absent
      env_example = Rails.root.join(".env.example").read
      found = FORBIDDEN_ENV_VARS.select { |env_var| env_example.match?(/^#{Regexp.escape(env_var)}=/) }
      check("forbidden Ethereal env vars absent", found.empty?, found.join(", "))
    end

    def production_files_do_not_reference_ethereal
      found = PRODUCTION_FILES.select { |path| Rails.root.join(path).read.match?(/Ethereal|ETHEREAL|HedgeBackends/) }
      check("production files do not reference Ethereal", found.empty?, found.join(", "))
    end

    def no_schema_or_migration_diff
      changed = git_diff_names.select do |path|
        path.match?(/schema|migration/) && Rails.root.join(path).exist? && Rails.root.join(path).read.match?(/ethereal/i)
      end
      check("no schema or migration files changed", changed.empty?, changed.join(", "))
    end

    def no_tracked_observations
      tracked = git_ls_files("storage/hedge_backends/ethereal_observations").reject(&:blank?)
      check("no tracked Ethereal observation files", tracked.empty?, tracked.join(", "))
    end

    def dangerous_endpoints_classified
      wrong = DANGEROUS_POLICY_ENDPOINTS.reject { |endpoint| EtherealEndpointPolicy.category(endpoint) == :dangerous_execution }
      check("dangerous endpoints classified as dangerous_execution", wrong.empty?, wrong.join(", "))
    end

    def observation_summary_live_adapter_false
      summary = EtherealObservationSummary.new(path: Rails.root.join("test/fixtures/files/hedge_backends/ethereal_probe_sample.json")).report
      check("observation summary live_adapter_allowed is false", summary.fetch(:live_adapter_allowed) == false, summary.fetch(:live_adapter_allowed).inspect)
    end

    def check(name, passed, detail)
      {
        name: name,
        status: passed ? "pass" : "fail",
        message: passed ? "#{name}: PASS" : "#{name}: FAIL #{detail}"
      }
    end

    def git_diff_names
      `git diff --name-only`.split("\n")
    end

    def git_ls_files(path)
      `git ls-files #{path}`.split("\n")
    end
  end
end

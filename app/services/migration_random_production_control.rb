require "fileutils"
require "securerandom"

class MigrationRandomProductionControl
  Result = Data.define(:ok, :status, :message, :command)
  CANARY_MODE = "canary_24h".freeze
  PRODUCTION_MODE = "production_24x7".freeze

  def initialize(
    service_name_template: ENV.fetch("RANDOM_PRODUCTION_SYSTEMD_SERVICE_TEMPLATE", "delta-neutral-random-production-%{position_id}.service"),
    canary_service_name_template: ENV.fetch("RANDOM_PRODUCTION_CANARY_SYSTEMD_SERVICE_TEMPLATE", "delta-neutral-random-production-%{position_id}-canary.service"),
    log_dir: MigrationRandomProductionRunner::LOG_DIR,
    control_mode: ENV.fetch("RANDOM_PRODUCTION_CONTROL_MODE", "auto"),
    systemctl_available: -> { self.class.systemctl_available? },
    now: -> { Time.current }
  )
    @service_name_template = service_name_template
    @canary_service_name_template = canary_service_name_template
    @log_dir = Pathname(log_dir)
    @control_mode = control_mode
    @systemctl_available = systemctl_available
    @now = now
  end

  def start(position:, mode:)
    bridge_mode = bridge_mode(mode)
    if use_direct_systemctl?
      run_systemctl("start", service_name(position.id, bridge_mode), mode: bridge_mode)
    else
      write_control_request(position: position, action: "start", mode: bridge_mode, confirmation_present: true)
    end
  end

  def stop(position:)
    MigrationRandomProductionRunner.new(position: position, live: false).stop!
    if use_direct_systemctl?
      run_systemctl("stop", service_name(position.id, PRODUCTION_MODE), mode: "stop")
    else
      write_control_request(position: position, action: "stop", mode: nil)
    end
  end

  def status(position:)
    run_systemctl("status", service_name(position.id), mode: "status")
  end

  def self.systemctl_available?
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "systemctl")) }
  end

  private

  attr_reader :service_name_template, :canary_service_name_template, :log_dir, :control_mode, :systemctl_available, :now

  def service_name(position_id, mode = PRODUCTION_MODE)
    template = mode == CANARY_MODE ? canary_service_name_template : service_name_template
    format(template, position_id: position_id)
  end

  def run_systemctl(action, service, mode:)
    command = [ "systemctl", action, service ]
    return Result.new(false, "unavailable", "systemctl is not available on this host", command) unless systemctl_available.call

    ok = system(*command, out: File::NULL, err: File::NULL)
    Result.new(ok, ok ? "submitted" : "failed", "#{action} #{service} #{ok ? 'submitted' : 'failed'} for #{mode}", command)
  end

  def use_direct_systemctl?
    return true if control_mode == "systemd"
    return false if control_mode == "bridge"

    systemctl_available.call
  end

  def bridge_mode(mode)
    mode.to_s == "production" || mode.to_s == PRODUCTION_MODE ? PRODUCTION_MODE : CANARY_MODE
  end

  def write_control_request(position:, action:, mode:, confirmation_present: nil)
    FileUtils.mkdir_p(log_dir)
    payload = {
      action: action,
      position_id: position.id,
      requested_at: now.call.utc.iso8601,
      request_id: SecureRandom.uuid
    }
    payload[:mode] = mode if mode
    payload[:confirmation_present] = confirmation_present unless confirmation_present.nil?
    atomic_write(control_path(position.id), JSON.pretty_generate(payload))
    Result.new(true, "pending", "host bridge control request written", [ "host_bridge", action, mode ].compact)
  rescue SystemCallError => e
    Result.new(false, "failed", "#{e.class}: #{e.message}", [ "host_bridge", action, mode ].compact)
  end

  def atomic_write(path, content)
    tmp_path = path.sub_ext("#{path.extname}.#{Process.pid}.tmp")
    File.write(tmp_path, content)
    File.rename(tmp_path, path)
  end

  def control_path(position_id)
    log_dir.join("control_position_#{position_id}.json")
  end
end

class MigrationRandomProductionControl
  Result = Data.define(:ok, :status, :message, :command)

  def initialize(service_name_template: ENV.fetch("RANDOM_PRODUCTION_SYSTEMD_SERVICE_TEMPLATE", "delta-neutral-random-production-%{position_id}.service"))
    @service_name_template = service_name_template
  end

  def start(position:, mode:)
    run_systemctl("start", service_name(position.id), mode: mode)
  end

  def stop(position:)
    MigrationRandomProductionRunner.new(position: position, live: false).stop!
    run_systemctl("stop", service_name(position.id), mode: "stop")
  end

  def status(position:)
    run_systemctl("status", service_name(position.id), mode: "status")
  end

  private

  attr_reader :service_name_template

  def service_name(position_id)
    format(service_name_template, position_id: position_id)
  end

  def run_systemctl(action, service, mode:)
    command = [ "systemctl", action, service ]
    return Result.new(false, "unavailable", "systemctl is not available on this host", command) unless systemctl_available?

    ok = system(*command, out: File::NULL, err: File::NULL)
    Result.new(ok, ok ? "submitted" : "failed", "#{action} #{service} #{ok ? 'submitted' : 'failed'} for #{mode}", command)
  end

  def systemctl_available?
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "systemctl")) }
  end
end

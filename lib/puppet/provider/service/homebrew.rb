# frozen_string_literal: true

require 'puppet/provider/service/base'
require 'puppet_x/homebrew/provider_support'

Puppet::Type.type(:service).provide :homebrew, parent: :base do
  extend PuppetX::Homebrew::ProviderSupport

  desc "Service management via Homebrew `brew services` on macOS.

    The resource name must be a Homebrew formula name that exposes a `service`
    definition."

  confine 'os.name' => :darwin
  confine 'os.architecture' => :arm64
  confine exists: '/opt/homebrew/bin/brew', for_binary: true

  has_feature :enableable, :refreshable

  def self.system_launchd_directory
    '/Library/LaunchDaemons'
  end

  def self.user_launchd_directory(owner)
    File.join(owner[:home], 'Library/LaunchAgents')
  end

  def self.run_brew(arguments, owner:, failonfail: true)
    ensure_execution_user!(owner, provider_label: 'service provider')

    if Process.uid.zero?
      return execute_as_owner([brew_executable] + arguments, owner, failonfail) unless arguments.first == 'services'

      return execute_with_environment([brew_executable] + arguments, owner, failonfail)
    end

    execute_as_owner([brew_executable] + arguments, owner, failonfail)
  end

  def self.execute_as_owner(command, owner, failonfail)
    options = execute_options(owner, failonfail)
    options[:uid] = owner[:uid]
    options[:gid] = owner[:gid]

    execute(command, options)
  end

  def self.execute_with_environment(command, owner, failonfail)
    execute(command, execute_options(owner, failonfail))
  end

  def self.execute_options(owner, failonfail)
    {
      failonfail: failonfail,
      combine: true,
      custom_environment: brew_environment(owner),
    }
  end

  def status
    service_state.fetch('running') ? :running : :stopped
  end

  def enabled?
    service_state.fetch('registered') ? :true : :false
  end

  def start
    current_state = service_state
    transition_to_running!(target_registration_for_ensure(current_state))
    nil
  end

  def stop
    current_state = service_state
    transition_to_stopped!(target_registration_for_ensure(current_state))
    nil
  end

  def enable
    service_state

    if desired_ensure == :running
      transition_to_running!(true)
    else
      run_service_command!('start')
      run_service_command!('kill')
    end

    nil
  end

  def disable
    service_state

    if desired_ensure == :running
      require_unregistered_running_supported!
    end

    run_service_command!('stop')

    if desired_ensure == :running
      run_service_command!('run')
    end

    nil
  end

  def restart
    current_state = service_state
    target_registration = desired_enable
    target_registration = current_state.fetch('registered') if target_registration.nil?

    require_unregistered_running_supported! unless target_registration

    if target_registration
      if current_state.fetch('registered')
        run_service_command!('restart')
      else
        run_service_command!('stop') if current_state.fetch('running')
        run_service_command!('start')
      end
    else
      run_service_command!('stop') if current_state.fetch('running') || current_state.fetch('registered')
      run_service_command!('run')
    end

    nil
  end

  private

  def self.prefetch(resources)
    instances.each do |prov|
      resource = resources[prov.name]
      resource.provider = prov if resource
    end
  end

  def self.instances
    owner = brew_owner
    arguments = ['services', 'info', '--all', '--json']
    output = run_brew(arguments, owner: owner, failonfail: false)
    return [] unless output.exitstatus.zero?

    Array(parse_json_output(output.to_s, arguments)).map do |record|
      new(
        name: record.fetch('name'),
        provider: name,
      )
    end
  rescue Puppet::Error
    []
  end

  def formula_record
    @formula_record ||= begin
      arguments = ['info', '--json=v2', '--formula', @resource[:name]]
      output = self.class.run_brew(arguments, owner: owner, failonfail: false)

      unless output.exitstatus.zero?
        message = self.class.primary_output_line(output) || "brew #{arguments.join(' ')} exited with status #{output.exitstatus}"
        raise Puppet::Error, message
      end

      data = self.class.parse_json_output(output.to_s, arguments)
      formula = data.fetch('formulae', []).first
      raise Puppet::Error, "Homebrew formula '#{@resource[:name]}' was not found" if formula.nil?
      raise Puppet::Error, "Homebrew formula '#{@resource[:name]}' does not define a service" if formula['service'].nil?

      formula
    end
  end

  def service_state
    @service_state ||= begin
      formula_record

      arguments = ['services', 'info', @resource[:name], '--json']
      output = self.class.run_brew(arguments, owner: owner, failonfail: false)

      unless output.exitstatus.zero?
        message = self.class.primary_output_line(output) || "brew #{arguments.join(' ')} exited with status #{output.exitstatus}"
        raise Puppet::Error, message
      end

      data = self.class.parse_json_output(output.to_s, arguments)
      record = Array(data).first
      raise Puppet::Error, "Homebrew service '#{@resource[:name]}' did not return service information" if record.nil?

      ensure_expected_registration_domain!(record)
      record
    end
  end

  def owner
    @owner ||= self.class.brew_owner
  end

  def desired_enable
    case @resource[:enable]
    when :true, true
      true
    when :false, false
      false
    else
      nil
    end
  end

  def desired_ensure
    @resource[:ensure]
  end

  def target_registration_for_ensure(current_state)
    desired = desired_enable
    return desired unless desired.nil?

    current_state.fetch('registered')
  end

  def transition_to_running!(registered)
    require_unregistered_running_supported! unless registered

    run_service_command!(registered ? 'start' : 'run')
  end

  def transition_to_stopped!(registered)
    run_service_command!(registered ? 'kill' : 'stop')
  end

  def run_service_command!(verb)
    arguments = ['services', verb, @resource[:name]]
    output = self.class.run_brew(arguments, owner: owner, failonfail: false)
    @service_state = nil

    return output if output.exitstatus.zero?

    message = self.class.primary_output_line(output) || "brew services #{verb} exited with status #{output.exitstatus}"
    raise Puppet::Error, message
  end

  def ensure_expected_registration_domain!(record)
    service_name = record.fetch('service_name')
    opposite_path = if Process.uid.zero?
                      File.join(self.class.user_launchd_directory(owner), "#{service_name}.plist")
                    else
                      File.join(self.class.system_launchd_directory, "#{service_name}.plist")
                    end

    return unless File.exist?(opposite_path)

    current_path = if Process.uid.zero?
                     File.join(self.class.system_launchd_directory, "#{service_name}.plist")
                   else
                     File.join(self.class.user_launchd_directory(owner), "#{service_name}.plist")
                   end

    raise Puppet::Error,
          "Homebrew service '#{@resource[:name]}' is registered in #{opposite_path}; manage it from the matching Puppet run context instead of migrating it implicitly from #{current_path}"
  end

  def require_unregistered_running_supported!
    return unless Process.uid.zero?

    raise Puppet::Error,
          "Homebrew cannot run '#{@resource[:name]}' unregistered as root; use enable => true for system services or run Puppet as #{owner[:name]} for login-session services"
  end
end

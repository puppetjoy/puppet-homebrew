# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'puppet/provider/service/homebrew'
require 'puppet/util/execution'

describe Puppet::Type.type(:service).provider(:homebrew) do
  let(:service_type) { Puppet::Type.type(:service) }
  let(:service_name) { 'openvpn' }
  let(:resource) { service_type.new(name: service_name, provider: :homebrew) }
  let(:provider) { described_class.new(resource) }
  let(:brew_owner_entry) { instance_double(Etc::Passwd, name: 'joy', dir: '/Users/joy') }
  let(:brew_prefix_stat) { instance_double(File::Stat, uid: 1000, gid: 1000) }

  def process_output(value, exitstatus: 0)
    Puppet::Util::Execution::ProcessOutput.new(value, exitstatus)
  end

  def formula_info_output(name: service_name, service: { 'run' => ["/opt/homebrew/opt/#{name}/bin/#{name}"] })
    process_output(JSON.generate('formulae' => [{ 'name' => name, 'service' => service }]))
  end

  def service_info_output(
    name: service_name,
    service_name_value: "homebrew.mxcl.#{name}",
    running: false,
    loaded: false,
    registered: false,
    user: nil,
    file: "/Users/joy/Library/LaunchAgents/homebrew.mxcl.#{name}.plist",
    status: 'none'
  )
    process_output(
      JSON.generate(
        [
          {
            'name' => name,
            'service_name' => service_name_value,
            'running' => running,
            'loaded' => loaded,
            'registered' => registered,
            'user' => user,
            'file' => file,
            'status' => status,
          },
        ],
      ),
    )
  end

  before(:each) do
    allow(File).to receive(:stat).with(described_class.brew_prefix).and_return(brew_prefix_stat)
    allow(Etc).to receive(:getpwuid).with(1000).and_return(brew_owner_entry)
    allow(Process).to receive(:uid).and_return(1000)
    allow(File).to receive(:exist?).and_return(false)
  end

  it 'is opt-in and pinned to the Apple Silicon Homebrew path' do
    expect(described_class.brew_prefix).to eq('/opt/homebrew')
    expect(described_class.brew_executable).to eq('/opt/homebrew/bin/brew')
    expect(described_class.default_match).to be_nil
  end

  describe '.instances' do
    it 'lists available Homebrew services for the current execution domain' do
      expect(described_class).to receive(:execute)
        .with(
          [described_class.brew_executable, 'services', 'info', '--all', '--json'],
          hash_including(
            uid: 1000,
            gid: 1000,
            failonfail: false,
            combine: true,
          ),
        )
        .and_return(
          process_output(
            JSON.generate(
              [
                {
                  'name' => 'openvpn',
                  'service_name' => 'homebrew.mxcl.openvpn',
                  'running' => false,
                  'registered' => true,
                },
              ],
            ),
          ),
        )

      expect(described_class.instances.map(&:name)).to eq(['openvpn'])
    end
  end

  describe '#status' do
    it 'returns running for a running registered service' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.status).to eq(:running)
    end

    it 'returns stopped for a registered but not running service' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(registered: true, user: 'root')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.status).to eq(:stopped)
    end

    it 'returns stopped for an unregistered stopped service' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.status).to eq(:stopped)
      expect(provider.enabled?).to eq(:false)
    end

    it 'raises the primary Homebrew error line for a missing formula' do
      allow(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .and_return(process_output("Error: No available formula with the name \"openvpn\"\n", exitstatus: 1))

      expect { provider.status }.to raise_error(Puppet::Error, %r{\ANo available formula with the name "openvpn"})
    end

    it 'raises when the formula does not define a Homebrew service' do
      allow(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .and_return(formula_info_output(service: nil))

      expect { provider.status }.to raise_error(Puppet::Error, %r{does not define a service})
    end

    it 'rejects a service registered in the opposite launchd domain' do
      allow(File).to receive(:exist?).with('/Library/LaunchDaemons/homebrew.mxcl.openvpn.plist').and_return(true)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect { provider.status }.to raise_error(Puppet::Error, %r{registered in /Library/LaunchDaemons})
    end
  end

  describe 'execution policy' do
    it 'runs root queries as root with the brew-owner environment' do
      allow(Process).to receive(:uid).and_return(0)

      expect(described_class).to receive(:execute).with(
        [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'],
        hash_including(
          uid: 1000,
          gid: 1000,
          failonfail: false,
          combine: true,
          custom_environment: {
            'HOME' => '/Users/joy',
            'USER' => 'joy',
            'LOGNAME' => 'joy',
            'PATH' => described_class.execution_path,
          },
        ),
      ).and_return(formula_info_output)

      expect(described_class).to receive(:execute).with(
        [described_class.brew_executable, 'services', 'info', 'openvpn', '--json'],
        satisfy do |options|
          options[:failonfail] == false &&
            options[:combine] == true &&
            options[:custom_environment] == {
              'HOME' => '/Users/joy',
              'USER' => 'joy',
              'LOGNAME' => 'joy',
              'PATH' => described_class.execution_path,
            } &&
            !options.key?(:uid) &&
            !options.key?(:gid)
        end,
      ).and_return(service_info_output)

      expect(provider.status).to eq(:stopped)
    end

    it 'runs as the brew owner with uid and gid set' do
      expect(described_class).to receive(:execute)
        .with(
          [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'],
          hash_including(
            uid: 1000,
            gid: 1000,
            failonfail: false,
            combine: true,
            custom_environment: {
              'HOME' => '/Users/joy',
              'USER' => 'joy',
              'LOGNAME' => 'joy',
              'PATH' => described_class.execution_path,
            },
          ),
        )
        .and_return(formula_info_output)

      expect(described_class).to receive(:execute)
        .with(
          [described_class.brew_executable, 'services', 'info', 'openvpn', '--json'],
          hash_including(
            uid: 1000,
            gid: 1000,
            failonfail: false,
            combine: true,
            custom_environment: {
              'HOME' => '/Users/joy',
              'USER' => 'joy',
              'LOGNAME' => 'joy',
              'PATH' => described_class.execution_path,
            },
          ),
        )
        .and_return(service_info_output)

      expect(provider.status).to eq(:stopped)
    end

    it 'fails when run unprivileged as some other user' do
      allow(Process).to receive(:uid).and_return(501)

      expect(described_class).not_to receive(:execute)
      expect { provider.status }.to raise_error(Puppet::Error, %r{must run as root or as joy})
    end
  end

  describe '#start' do
    it 'uses brew services start when ensure is running and enable is true' do
      start_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: true)
      start_provider = described_class.new(start_resource)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        when [described_class.brew_executable, 'services', 'start', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(start_provider.start).to be_nil
    end

    it 'uses brew services run when ensure is running and enable is false' do
      start_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      start_provider = described_class.new(start_resource)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        when [described_class.brew_executable, 'services', 'run', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(start_provider.start).to be_nil
    end

    it 'fails before mutation when asked to run unregistered as root' do
      start_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      start_provider = described_class.new(start_resource)

      allow(Process).to receive(:uid).and_return(0)
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect { start_provider.start }.to raise_error(Puppet::Error, %r{cannot run 'openvpn' unregistered as root})
    end

    it 'preserves current unregistered state when enable is unmanaged' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output
        when [described_class.brew_executable, 'services', 'run', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.start).to be_nil
    end
  end

  describe '#stop' do
    it 'uses brew services kill when ensure is stopped and enable is true' do
      stop_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :stopped, enable: true)
      stop_provider = described_class.new(stop_resource)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        when [described_class.brew_executable, 'services', 'kill', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(stop_provider.stop).to be_nil
    end

    it 'uses brew services stop when ensure is stopped and enable is false' do
      stop_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :stopped, enable: false)
      stop_provider = described_class.new(stop_resource)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        when [described_class.brew_executable, 'services', 'stop', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(stop_provider.stop).to be_nil
    end

    it 'preserves current registered state when enable is unmanaged' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        when [described_class.brew_executable, 'services', 'kill', 'openvpn']
          process_output('')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.stop).to be_nil
    end
  end

  describe '#enable' do
    it 'starts and registers a running service' do
      enable_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: true)
      enable_provider = described_class.new(enable_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'start', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(enable_provider.enable).to be_nil
    end

    it 'registers a stopped service without leaving it running' do
      enable_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :stopped, enable: true)
      enable_provider = described_class.new(enable_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'start', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'kill', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(enable_provider.enable).to be_nil
    end
  end

  describe '#disable' do
    it 'restarts a running service as unregistered when enable is false' do
      disable_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      disable_provider = described_class.new(disable_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started'))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'stop', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'run', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(disable_provider.disable).to be_nil
    end

    it 'fails before stopping when root cannot keep the service running unregistered' do
      disable_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      disable_provider = described_class.new(disable_resource)

      allow(Process).to receive(:uid).and_return(0)
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect { disable_provider.disable }.to raise_error(Puppet::Error, %r{cannot run 'openvpn' unregistered as root})
    end

    it 'stops and unregisters a stopped service' do
      disable_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :stopped, enable: false)
      disable_provider = described_class.new(disable_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output(registered: true, user: 'root'))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'stop', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(disable_provider.disable).to be_nil
    end
  end

  describe '#restart' do
    it 'uses brew services restart for registered services' do
      restart_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: true)
      restart_provider = described_class.new(restart_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started'))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'restart', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(restart_provider.restart).to be_nil
    end

    it 'stops and runs an unregistered service without registering it' do
      restart_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      restart_provider = described_class.new(restart_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output(running: true, loaded: true, registered: false, file: '/Users/joy/Library/LaunchAgents/homebrew.mxcl.openvpn.plist', status: 'started'))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'stop', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'run', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(restart_provider.restart).to be_nil
    end

    it 'fails before mutation when asked to restart unregistered as root' do
      restart_resource = service_type.new(name: 'openvpn', provider: :homebrew, ensure: :running, enable: false)
      restart_provider = described_class.new(restart_resource)

      allow(Process).to receive(:uid).and_return(0)
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn']
          formula_info_output
        when [described_class.brew_executable, 'services', 'info', 'openvpn', '--json']
          service_info_output(running: true, loaded: true, registered: true, user: 'root', status: 'started')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect { restart_provider.restart }.to raise_error(Puppet::Error, %r{cannot run 'openvpn' unregistered as root})
    end

    it 'preserves current registration when enable is unmanaged' do
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--formula', 'openvpn'], anything)
        .ordered
        .and_return(formula_info_output)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'info', 'openvpn', '--json'], anything)
        .ordered
        .and_return(service_info_output(running: true, loaded: true, registered: false, status: 'started'))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'stop', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'services', 'run', 'openvpn'], anything)
        .ordered
        .and_return(process_output(''))

      expect(provider.restart).to be_nil
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'puppet/provider/package/homebrew'
require 'puppet/util/execution'

describe Puppet::Type.type(:package).provider(:homebrew) do
  let(:package_type) { Puppet::Type.type(:package) }
  let(:package_name) { 'pcre2' }
  let(:resource) { package_type.new(name: package_name, provider: :homebrew) }
  let(:provider) { described_class.new(resource) }
  let(:brew_owner_entry) { instance_double(Etc::Passwd, name: 'joy', dir: '/Users/joy') }
  let(:brew_prefix_stat) { instance_double(File::Stat, uid: 1000, gid: 1000) }

  def fixture_path(name)
    File.expand_path("../../../../fixtures/homebrew/#{name}", __dir__)
  end

  def fixture_output(name, exitstatus: 0)
    Puppet::Util::Execution::ProcessOutput.new(File.read(fixture_path(name)), exitstatus)
  end

  def string_output(value, exitstatus: 0)
    Puppet::Util::Execution::ProcessOutput.new(value, exitstatus)
  end

  before(:each) do
    described_class.instance_variable_set(:@brew_owner, nil)
    described_class.instance_variable_set(:@formula_record_cache, nil)
    described_class.instance_variable_set(:@cask_record_cache, nil)

    allow(File).to receive(:stat).with(described_class.brew_prefix).and_return(brew_prefix_stat)
    allow(Etc).to receive(:getpwuid).with(1000).and_return(brew_owner_entry)
    allow(Process).to receive(:uid).and_return(1000)
  end

  it 'is opt-in and pinned to the Apple Silicon Homebrew path' do
    expect(described_class.brew_prefix).to eq('/opt/homebrew')
    expect(described_class.brew_executable).to eq('/opt/homebrew/bin/brew')
    expect(described_class.default_match).to be_nil
  end

  describe '.instances' do
    it 'returns installed formulae and casks, disambiguating colliding names' do
      allow(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--installed'], anything)
        .and_return(fixture_output('installed_inventory.json'))

      instances = described_class.instances

      expect(instances.map(&:name)).to contain_exactly(
        'tmux',
        'pcre2',
        'chatgpt',
        'homebrew/core/docker',
        'homebrew/cask/docker',
      )
      expect(instances.find { |pkg| pkg.name == 'pcre2' }.properties[:ensure]).to eq(['10.46', '10.47_1'])
      expect(instances.find { |pkg| pkg.name == 'chatgpt' }.properties[:ensure]).to eq('1.2026.048,1771630681')
    end

    it 'parses installed inventory when Homebrew prefixes progress lines before JSON' do
      output = <<~OUTPUT
        ✔︎ JSON API formula_tap_migrations.jws.json
        ✔︎ JSON API cask_tap_migrations.jws.json
        #{File.read(fixture_path('installed_inventory.json'))}
      OUTPUT

      allow(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--installed'], anything)
        .and_return(string_output(output))

      expect(described_class.instances.map(&:name)).to contain_exactly(
        'tmux',
        'pcre2',
        'chatgpt',
        'homebrew/core/docker',
        'homebrew/cask/docker',
      )
    end

    it 'runs inventory queries through sudo when the provider is invoked as root' do
      allow(Process).to receive(:uid).and_return(0)

      expect(described_class).to receive(:execute).with(
        [
          described_class.sudo_executable,
          '-n',
          '-H',
          '-u',
          'joy',
          '--',
          described_class.env_executable,
          'HOME=/Users/joy',
          'USER=joy',
          'LOGNAME=joy',
          "PATH=#{described_class.execution_path}",
          described_class.brew_executable,
          'info',
          '--json=v2',
          '--installed',
        ],
        hash_including(failonfail: false, combine: true),
      ).and_return(fixture_output('installed_inventory.json'))

      expect(described_class.instances.map(&:name)).to contain_exactly(
        'tmux',
        'pcre2',
        'chatgpt',
        'homebrew/core/docker',
        'homebrew/cask/docker',
      )
    end
  end

  describe '#query' do
    it 'returns installed formula metadata' do
      missing_cask_output = string_output("Error: Cask 'pcre2' is unavailable: No Cask with this name exists.\n", exitstatus: 1)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'pcre2']
          fixture_output('info_formula_pcre2.json')
        when [described_class.brew_executable, 'info', '--json=v2', '--cask', 'pcre2']
          missing_cask_output
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.query).to eq(
        name: 'pcre2',
        ensure: ['10.46', '10.47_1'],
        provider: :homebrew,
      )
    end

    it 'returns installed cask metadata' do
      cask_resource = package_type.new(name: 'chatgpt', provider: :homebrew)
      cask_provider = described_class.new(cask_resource)

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'chatgpt']
          fixture_output('absent.json')
        when [described_class.brew_executable, 'info', '--json=v2', '--cask', 'chatgpt']
          fixture_output('info_cask_chatgpt.json')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(cask_provider.query).to eq(
        name: 'chatgpt',
        ensure: '1.2026.048,1771630681',
        provider: :homebrew,
      )
    end

    it 'returns nil for a package that does not exist' do
      missing_output = string_output("Error: No formulae or casks found for \"ghost\"\n", exitstatus: 1)

      allow(described_class).to receive(:execute).and_return(missing_output)

      expect(described_class.new(package_type.new(name: 'ghost', provider: :homebrew)).query).to be_nil
    end

    it 'raises for ambiguous names without explicit package type' do
      ambiguous_provider = described_class.new(package_type.new(name: 'docker', provider: :homebrew))

      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'docker']
          fixture_output('info_formula_docker.json')
        when [described_class.brew_executable, 'info', '--json=v2', '--cask', 'docker']
          fixture_output('info_cask_docker.json')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect { ambiguous_provider.query }.to raise_error(Puppet::Error, %r{ambiguous})
    end

    it 'accepts explicit cask selection for ambiguous names' do
      ambiguous_resource = package_type.new(
        name: 'docker',
        provider: :homebrew,
        install_options: ['--cask'],
      )
      ambiguous_provider = described_class.new(ambiguous_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'info', '--json=v2', '--cask', 'docker'], anything)
        .and_return(fixture_output('info_cask_docker.json'))

      expect(ambiguous_provider.query).to eq(
        name: 'docker',
        ensure: '4.41.0',
        provider: :homebrew,
      )
    end
  end

  describe '#latest' do
    it 'includes formula revisions in the latest version' do
      allow(described_class).to receive(:execute).and_wrap_original do |_original, command, _options|
        case command
        when [described_class.brew_executable, 'info', '--json=v2', '--formula', 'pcre2']
          fixture_output('info_formula_pcre2.json')
        when [described_class.brew_executable, 'info', '--json=v2', '--cask', 'pcre2']
          fixture_output('absent.json')
        else
          raise "unexpected command #{command.inspect}"
        end
      end

      expect(provider.latest).to eq('10.47_1')
    end
  end

  describe '#install' do
    it 'builds a forced brew install command' do
      install_resource = package_type.new(
        name: 'chatgpt',
        provider: :homebrew,
        install_options: ['--cask'],
      )
      install_provider = described_class.new(install_resource)

      expect(described_class).to receive(:execute).with(
        [described_class.brew_executable, 'install', '--cask', '--force', 'chatgpt'],
        hash_including(
          uid: 1000,
          gid: 1000,
          failonfail: true,
          combine: true,
          custom_environment: hash_including('HOME' => '/Users/joy'),
        ),
      ).and_return(string_output(''))

      install_provider.install
    end

    it 'rejects exact version ensure values' do
      allow(resource).to receive(:should).with(:ensure).and_return('10.47_1')

      expect { provider.install }.to raise_error(Puppet::Error, %r{does not support exact version})
    end

    it 'creates and cleans up temporary sudoers access when running as root' do
      install_resource = package_type.new(
        name: 'chatgpt',
        provider: :homebrew,
        install_options: ['--cask'],
      )
      install_provider = described_class.new(install_resource)
      temp_path = %r{\A/etc/sudoers\.d/puppet-homebrew-\d+-[0-9a-f]{12}\z}

      allow(Process).to receive(:uid).and_return(0)
      allow(File).to receive(:executable?).with(described_class.visudo_executable).and_return(true)
      allow(File).to receive(:exist?) { |path| path.match?(temp_path) }

      expect(File).to receive(:write).with(temp_path, include('joy ALL=(root) NOPASSWD: ALL')).ordered
      expect(File).to receive(:chmod).with(0o440, temp_path).ordered
      expect(described_class).to receive(:execute)
        .with([described_class.visudo_executable, '-cf', kind_of(String)], hash_including(failonfail: true, combine: true))
        .ordered
        .and_return(string_output(''))
      expect(described_class).to receive(:execute)
        .with(
          [
            described_class.sudo_executable,
            '-n',
            '-H',
            '-u',
            'joy',
            '--',
            described_class.env_executable,
            'HOME=/Users/joy',
            'USER=joy',
            'LOGNAME=joy',
            "PATH=#{described_class.execution_path}",
            described_class.brew_executable,
            'install',
            '--cask',
            '--force',
            'chatgpt',
          ],
          hash_including(failonfail: true, combine: true),
        )
        .ordered
        .and_return(string_output(''))
      expect(File).to receive(:delete).with(temp_path).ordered

      install_provider.install
    end

    it 'fails when run unprivileged as a user other than the brew owner' do
      allow(Process).to receive(:uid).and_return(501)

      expect(described_class).not_to receive(:execute)
      expect { provider.install }.to raise_error(Puppet::Error, %r{must run as root or as joy})
    end
  end

  describe '#update' do
    it 'installs when latest is requested for an absent package' do
      latest_resource = package_type.new(
        name: 'chatgpt',
        provider: :homebrew,
        ensure: :latest,
        install_options: ['--cask'],
      )
      latest_provider = described_class.new(latest_resource)

      allow(latest_provider).to receive(:query).and_return(nil)
      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'install', '--cask', '--force', 'chatgpt'], anything)
        .and_return(string_output(''))

      latest_provider.update
    end
  end

  describe '#uninstall' do
    it 'builds a forced brew uninstall command' do
      uninstall_resource = package_type.new(
        name: 'chatgpt',
        provider: :homebrew,
        uninstall_options: ['--cask'],
      )
      uninstall_provider = described_class.new(uninstall_resource)

      expect(described_class).to receive(:execute)
        .with([described_class.brew_executable, 'uninstall', '--cask', '--force', 'chatgpt'], anything)
        .and_return(string_output(''))

      uninstall_provider.uninstall
    end
  end
end

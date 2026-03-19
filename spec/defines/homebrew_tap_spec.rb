# frozen_string_literal: true

require 'spec_helper'

describe 'homebrew::tap' do
  let(:title) { 'puppetlabs/puppet' }
  let(:base_facts) do
    {
      os: {
        'name' => 'Darwin',
        'architecture' => 'arm64',
        'release' => {
          'major' => '25',
        },
      },
      identity: {
        'user' => 'root',
      },
      homebrew_owner: 'joy',
      homebrew_clt_installed: true,
    }
  end

  let(:facts) { base_facts }

  context 'with default parameters' do
    it { is_expected.to compile }

    it do
      is_expected.to contain_exec('homebrew tap puppetlabs/puppet').with(
        command: ['/usr/bin/sudo', '-H', '-u', 'joy', '--', '/opt/homebrew/bin/brew', 'tap', 'puppetlabs/puppet'],
        unless: ['/bin/sh', '-c', "/usr/bin/sudo -H -u 'joy' -- /opt/homebrew/bin/brew tap-info --json=v1 'puppetlabs/puppet' | /usr/bin/grep -q '\"installed\":[[:space:]]*true'"],
        environment: ['PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'],
        path: ['/opt/homebrew/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      )
    end
  end

  context 'when a custom source is specified' do
    let(:params) do
      {
        source: 'https://github.com/openvoxproject/homebrew-openvox',
      }
    end
    let(:title) { 'openvoxproject/openvox' }

    it do
      is_expected.to contain_exec('homebrew tap openvoxproject/openvox').with(
        command: ['/usr/bin/sudo', '-H', '-u', 'joy', '--', '/opt/homebrew/bin/brew', 'tap', 'openvoxproject/openvox', 'https://github.com/openvoxproject/homebrew-openvox'],
      )
    end
  end

  context 'when ensure is absent' do
    let(:params) { { ensure: 'absent' } }

    it do
      is_expected.to contain_exec('homebrew untap puppetlabs/puppet').with(
        command: ['/usr/bin/sudo', '-H', '-u', 'joy', '--', '/opt/homebrew/bin/brew', 'untap', 'puppetlabs/puppet'],
        onlyif: ['/bin/sh', '-c', "/usr/bin/sudo -H -u 'joy' -- /opt/homebrew/bin/brew tap-info --json=v1 'puppetlabs/puppet' | /usr/bin/grep -q '\"installed\":[[:space:]]*true'"],
      )
    end
  end

  context 'when Puppet runs as the Homebrew owner' do
    let(:facts) do
      base_facts.merge(
        identity: {
          'user' => 'joy',
        },
      )
    end

    it do
      is_expected.to contain_exec('homebrew tap puppetlabs/puppet').with(
        command: ['/opt/homebrew/bin/brew', 'tap', 'puppetlabs/puppet'],
        unless: ['/bin/sh', '-c', "/opt/homebrew/bin/brew tap-info --json=v1 'puppetlabs/puppet' | /usr/bin/grep -q '\"installed\":[[:space:]]*true'"],
      )
    end
  end

  context 'when Puppet runs as another unprivileged user' do
    let(:facts) do
      base_facts.merge(
        identity: {
          'user' => 'alice',
        },
      )
    end

    it 'fails with a clear error' do
      expect { catalogue }.to raise_error(
        Puppet::Error,
        %r{must run as root or as joy},
      )
    end
  end

  context 'when the homebrew class provides install_user' do
    let(:pre_condition) do
      <<~PUPPET
        class { 'homebrew':
          install_user => 'penny',
        }
      PUPPET
    end

    it { is_expected.to compile }

    it do
      is_expected.to contain_exec('homebrew tap puppetlabs/puppet').with(
        command: ['/usr/bin/sudo', '-H', '-u', 'penny', '--', '/opt/homebrew/bin/brew', 'tap', 'puppetlabs/puppet'],
      ).that_requires('Package[Homebrew]')
    end
  end
end

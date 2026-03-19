# frozen_string_literal: true

require 'spec_helper'

describe 'homebrew' do
  let(:base_facts) do
    {
      os: {
        'name' => 'Darwin',
        'architecture' => 'arm64',
        'release' => {
          'major' => '25',
        },
      },
      homebrew_clt_installed: true,
    }
  end

  let(:facts) { base_facts }

  context 'with default parameters' do
    it { is_expected.to compile }

    it do
      is_expected.to contain_package('Homebrew').with(
        ensure: 'installed',
        provider: 'pkgdmg',
        source: 'https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg',
      )
    end

    it { is_expected.not_to contain_file('/var/tmp/.homebrew_pkg_user.plist') }
  end

  context 'when version is specified' do
    let(:params) { { version: '5.1.0' } }

    it do
      is_expected.to contain_package('Homebrew').with(
        source: 'https://github.com/Homebrew/brew/releases/download/5.1.0/Homebrew.pkg',
      )
    end
  end

  context 'when source is specified' do
    let(:params) { { source: 'https://example.test/Homebrew.pkg', version: '5.1.0' } }

    it do
      is_expected.to contain_package('Homebrew').with(
        source: 'https://example.test/Homebrew.pkg',
      )
    end
  end

  context 'when install_user is specified' do
    let(:params) { { install_user: 'penny' } }

    it { is_expected.to compile }

    it do
      is_expected.to contain_file('/var/tmp/.homebrew_pkg_user.plist').with(
        ensure: 'file',
        owner: 'root',
        group: 'wheel',
        mode: '0644',
        content: %r{<string>penny</string>},
      )
    end

    it do
      is_expected.to contain_package('Homebrew').that_requires('File[/var/tmp/.homebrew_pkg_user.plist]')
    end
  end

  context 'when ensure is absent' do
    let(:params) { { ensure: 'absent', install_user: 'penny' } }

    it { is_expected.to compile }

    it { is_expected.not_to contain_package('Homebrew') }

    it do
      is_expected.to contain_exec('forget homebrew package receipt').with(
        command: '/usr/sbin/pkgutil --forget sh.brew.homebrew',
        onlyif: '/usr/sbin/pkgutil --pkg-info sh.brew.homebrew >/dev/null 2>&1',
      )
    end

    it do
      is_expected.to contain_file('/opt/homebrew').with(
        ensure: 'absent',
        force: true,
      )
    end

    it { is_expected.to contain_file('/etc/paths.d/homebrew').with_ensure('absent') }
    it { is_expected.to contain_file('/var/db/.puppet_pkgdmg_installed_Homebrew').with_ensure('absent') }
    it { is_expected.to contain_file('/var/tmp/.homebrew_pkg_user.plist').with_ensure('absent') }
  end

  context 'when CLT is missing and the precheck is enabled' do
    let(:facts) { base_facts.merge(homebrew_clt_installed: false) }

    it 'fails before attempting installation' do
      expect { catalogue }.to raise_error(
        Puppet::Error,
        %r{Command Line Tools},
      )
    end
  end

  context 'when CLT is missing and the precheck is disabled' do
    let(:facts) { base_facts.merge(homebrew_clt_installed: false) }
    let(:params) { { require_clt: false } }

    it { is_expected.to compile }
  end

  context 'on Intel macOS' do
    let(:facts) do
      base_facts.merge(
        os: base_facts[:os].merge('architecture' => 'x86_64'),
      )
    end

    it 'fails with a clear error' do
      expect { catalogue }.to raise_error(
        Puppet::Error,
        %r{Apple Silicon},
      )
    end
  end

  context 'on an unsupported macOS release' do
    let(:facts) do
      base_facts.merge(
        os: base_facts[:os].merge('release' => { 'major' => '22' }),
      )
    end

    it 'fails with a clear error' do
      expect { catalogue }.to raise_error(
        Puppet::Error,
        %r{Sonoma},
      )
    end
  end
end

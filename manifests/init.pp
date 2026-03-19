# @summary Manage Homebrew installation through the official macOS package.
#
# This class is intentionally opt-in. Declare it when Puppet should manage the
# initial Homebrew installation, or leave it undeclared when Homebrew is
# installed separately.
#
# The implementation follows Homebrew's supported macOS package installation
# path and is limited to Apple Silicon hosts running macOS Sonoma or newer. The
# class does not manage the Xcode Command Line Tools; it only checks for their
# presence before installation unless `require_clt` is set to `false`.
#
# When no explicit `source` is provided, the installer defaults to Homebrew's
# latest GitHub release package. Use `version` to pin a release while still
# using the standard GitHub package URL, or `source` to provide an explicit
# local path or remote package URL.
#
# @example Install Homebrew from the latest release package
#   class { 'homebrew': }
#
# @example Install a specific Homebrew release
#   class { 'homebrew':
#     version => '5.1.0',
#   }
#
# @example Install Homebrew for an alternate existing user
#   class { 'homebrew':
#     install_user => 'penny',
#   }
#
# @example Remove Homebrew
#   class { 'homebrew':
#     ensure => 'absent',
#   }
#
# @param ensure
#   Whether Homebrew should be installed or removed.
# @param version
#   Optional Homebrew release tag used to build the default GitHub package URL.
#   Ignored when `source` is set.
# @param source
#   Optional explicit installer source. This may be a local path or a remote
#   package URL accepted by Puppet's `pkgdmg` provider.
# @param install_user
#   Optional existing macOS account name written to
#   `/var/tmp/.homebrew_pkg_user.plist` before installation so the Homebrew
#   package installs for that user.
# @param require_clt
#   Whether to fail early when the Command Line Tools are not installed, as
#   reported by the `homebrew_clt_installed` fact.
class homebrew (
  Enum['present', 'absent'] $ensure = 'present',
  Optional[String[1]] $version = undef,
  Optional[String[1]] $source = undef,
  Optional[String[1]] $install_user = undef,
  Boolean $require_clt = true,
) {
  if $facts['os']['name'] != 'Darwin' {
    fail('The homebrew class supports only macOS hosts.')
  }

  if $facts['os']['architecture'] != 'arm64' {
    fail('The homebrew class currently supports only Apple Silicon macOS hosts.')
  }

  if Integer($facts['os']['release']['major']) < 23 {
    fail('The homebrew class requires macOS Sonoma (Darwin 23) or newer.')
  }

  if $ensure == 'present' and $require_clt and !$facts['homebrew_clt_installed'] {
    fail('Homebrew requires the Command Line Tools before installation. Install them with xcode-select --install or set require_clt => false to skip this precheck.')
  }

  $installer_source = $source ? {
    undef   => $version ? {
      undef   => 'https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg',
      default => "https://github.com/Homebrew/brew/releases/download/${version}/Homebrew.pkg",
    },
    default => $source,
  }

  $pkg_user_plist_ensure = $ensure ? {
    'present' => file,
    'absent'  => absent,
  }

  $package_require = $install_user ? {
    undef   => undef,
    default => File['/var/tmp/.homebrew_pkg_user.plist'],
  }

  if $install_user {
    file { '/var/tmp/.homebrew_pkg_user.plist':
      ensure  => $pkg_user_plist_ensure,
      owner   => 'root',
      group   => 'wheel',
      mode    => '0644',
      content => epp('homebrew/homebrew_pkg_user.plist.epp', { 'install_user' => $install_user }),
    }
  }

  if $ensure == 'present' {
    package { 'Homebrew':
      ensure   => installed,
      provider => pkgdmg,
      source   => $installer_source,
      require  => $package_require,
    }
  } else {
    exec { 'forget homebrew package receipt':
      command => '/usr/sbin/pkgutil --forget sh.brew.homebrew',
      onlyif  => '/usr/sbin/pkgutil --pkg-info sh.brew.homebrew >/dev/null 2>&1',
      path    => ['/usr/bin', '/usr/sbin', '/bin', '/sbin'],
    }

    file { '/opt/homebrew':
      ensure => absent,
      force  => true,
    }

    file { [
        '/etc/paths.d/homebrew',
        '/var/db/.puppet_pkgdmg_installed_Homebrew',
      ]:
        ensure => absent,
    }
  }
}

# @summary Manage a Homebrew tap.
#
# Taps are managed through `brew tap` and `brew untap`, executed as the
# Homebrew owner rather than as raw `root`.
#
# When the `homebrew` class is declared with `install_user`, tap resources use
# that account so the initial Homebrew installation and tap management can
# happen in the same catalog run. Otherwise, the defined type falls back to the
# `homebrew_owner` fact for already-installed Homebrew prefixes.
#
# @example Add a tap from GitHub
#   homebrew::tap { 'puppetlabs/puppet': }
#
# @example Add a tap from a custom remote
#   homebrew::tap { 'openvoxproject/openvox':
#     source => 'https://github.com/openvoxproject/homebrew-openvox',
#   }
#
# @example Remove a tap
#   homebrew::tap { 'puppetlabs/puppet':
#     ensure => 'absent',
#   }
#
# @param ensure
#   Whether the tap should be present or absent.
# @param source
#   Optional custom remote URL passed as the second argument to `brew tap`.
define homebrew::tap (
  Enum['present', 'absent'] $ensure = 'present',
  Optional[String[1]] $source = undef,
) {
  if $title !~ Pattern[/\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\z/] {
    fail("Homebrew tap '${title}' must use the form 'user/repo'")
  }

  $class_install_user = defined(Class['homebrew']) ? {
    true    => $homebrew::install_user,
    default => undef,
  }

  $brew_owner = $class_install_user ? {
    undef   => $facts['homebrew_owner'],
    default => $class_install_user,
  }

  if $brew_owner == undef or $brew_owner == '' {
    fail("Homebrew tap '${title}' requires either homebrew::install_user from the homebrew class or the homebrew_owner fact")
  }

  $identity_user = $facts['identity']['user']

  if $identity_user == 'root' {
    $brew_command = ['/usr/bin/sudo', '-H', '-u', $brew_owner, '--', '/opt/homebrew/bin/brew']
    $brew_shell_command = "/usr/bin/sudo -H -u '${brew_owner}' -- /opt/homebrew/bin/brew"
  } elsif $identity_user == $brew_owner {
    $brew_command = ['/opt/homebrew/bin/brew']
    $brew_shell_command = '/opt/homebrew/bin/brew'
  } else {
    fail("Homebrew tap '${title}' must run as root or as ${brew_owner}, the owner of /opt/homebrew")
  }

  $tap_guard = "${brew_shell_command} tap-info --json=v1 '${title}' | /usr/bin/grep -q '\"installed\":[[:space:]]*true'"

  $tap_require = defined(Package['Homebrew']) ? {
    true    => Package['Homebrew'],
    default => undef,
  }

  if $ensure == 'present' {
    $tap_command = $source ? {
      undef   => $brew_command + ['tap', $title],
      default => $brew_command + ['tap', $title, $source],
    }

    exec { "homebrew tap ${title}":
      command => $tap_command,
      unless  => ['/bin/sh', '-c', $tap_guard],
      path    => ['/opt/homebrew/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require => $tap_require,
    }
  } else {
    exec { "homebrew untap ${title}":
      command => $brew_command + ['untap', $title],
      onlyif  => ['/bin/sh', '-c', $tap_guard],
      path    => ['/opt/homebrew/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'],
      require => $tap_require,
    }
  }
}

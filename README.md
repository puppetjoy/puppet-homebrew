# Homebrew Package Provider for Puppet

## Description

This module lets Puppet manage Homebrew on macOS without introducing a
separate resource model. Use the `homebrew` provider to manage formulae and
casks through Puppet's native `package` resource, the `homebrew` class to
install Homebrew from the official macOS `.pkg`, and `homebrew::tap` to
manage taps.

The scope is intentionally narrow and predictable: `/opt/homebrew` on Apple
Silicon, a small supported `ensure` surface, and one provider for both
formulae and casks. In most cases you declare packages the same way you always
would in Puppet, and only add `--cask` or `--formula` when Homebrew itself
needs disambiguation.

## Setup

### Requirements

- macOS on Apple Silicon
- macOS Sonoma (14) / Darwin 23 or newer
- Puppet 7.24 through Puppet 8
- Command Line Tools for Xcode

This module does not support Intel Homebrew under `/usr/local` or Linuxbrew.

### What The Provider Changes

- Runs `brew` as the owner of `/opt/homebrew`
- Supports `ensure => present|installed|latest|absent`
- Reports installed packages through the RAL inventory
- Forces install and uninstall operations with `--force` so Puppet can recover
  from drifted or partially orphaned Homebrew state

## Usage

If you want this module to manage Homebrew itself, declare the optional
`homebrew` class with an explicit `install_user` and an explicit relationship
for `provider => homebrew` packages:

```puppet
class { 'homebrew':
  install_user => 'penny',
}

Class['homebrew'] -> Package <| provider == 'homebrew' |>
```

Setting `install_user` is the most deterministic option, especially when
Puppet runs as a system service or otherwise outside the target user's login
session. You can also pin a release, override the installer source, or remove
Homebrew entirely. See the generated class reference for the full parameter
list.

Select the provider explicitly with `provider => homebrew` on package
resources that should be managed through Homebrew.

```puppet
package { 'tmux':
  ensure   => present,
  provider => homebrew,
}
```

Most packages can be managed without distinguishing between formulae and casks:

```puppet
package { 'chatgpt':
  ensure   => latest,
  provider => homebrew,
}
```

When Homebrew needs explicit disambiguation, pass the normal Homebrew flag
through `install_options` and `uninstall_options`:

```puppet
package { 'firefox':
  ensure            => latest,
  provider          => homebrew,
  install_options   => ['--cask'],
  uninstall_options => ['--cask'],
}
```

The provider intentionally supports only `present`, `installed`, `latest`, and
`absent` for `ensure`. Exact version `ensure` values are not supported.

Manage taps with the `homebrew::tap` defined type:

```puppet
homebrew::tap { 'puppetlabs/puppet': }
```

You can also specify a custom remote URL or remove a tap:

```puppet
homebrew::tap { 'openvoxproject/openvox':
  source => 'https://github.com/openvoxproject/homebrew-openvox',
}

homebrew::tap { 'puppetlabs/puppet':
  ensure => absent,
}
```

Tap resources resolve the Homebrew owner from `install_user` on the declared
`homebrew` class when available, and otherwise from the `homebrew_owner` fact
that inspects `/opt/homebrew`. v1 intentionally does not expose extra tap
flags such as `--custom-remote` or `--force`.

## Security Caveat

Homebrew expects to run as the owner of `/opt/homebrew`, while Puppet often
runs as `root`. Some cask installs also require non-interactive `sudo`.

When the provider performs a mutating action from a root Puppet run, it creates
a temporary file under `/etc/sudoers.d`, validates it with `visudo`, runs the
Homebrew command as the Homebrew owner, and then removes the file immediately
afterward.

The temporary rule grants the Homebrew owner `NOPASSWD` root access for the
duration of the provider action. This is an intentional compromise to make
Homebrew cask behavior work inside Puppet's desired-state model, and it should
be considered carefully before use in security-sensitive environments.

## Limitations

- Apple Silicon macOS only
- `/opt/homebrew` only
- Only `present`, `installed`, `latest`, and `absent` are supported for
  `ensure`
- Tap management supports only `ensure => present|absent` and an optional
  custom source URL
- Ambiguous names that exist as both formulae and casks require explicit
  `--formula` or `--cask` options

## Development

Validation for this module should use PDK:

```shell
pdk validate
pdk test unit
```

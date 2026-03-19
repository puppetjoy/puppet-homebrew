# Homebrew for Puppet

## Overview

This module manages Homebrew as a macOS package-management system, not just as
a package provider.

It provides:

- The `homebrew` class to install or remove Homebrew through the supported
  macOS `.pkg`
- A `homebrew` provider for Puppet's native `package` resource to manage
  formulae and casks
- A `homebrew::tap` defined type to manage taps
- A `homebrew` provider for Puppet's native `service` resource to manage
  formula services through `brew services`

The module is intentionally narrow and predictable:

- macOS only
- `/opt/homebrew` only
- arm64 only
- Homebrew commands run either as `root` with the Homebrew owner's environment
  or directly as the Homebrew owner

## Table Of Contents

- [Requirements](#requirements)
- [How It Works](#how-it-works)
- [Usage](#usage)
  - [Install Or Remove Homebrew](#install-or-remove-homebrew)
  - [Manage Packages](#manage-packages)
  - [Manage Taps](#manage-taps)
  - [Manage Services](#manage-services)
- [Execution Model](#execution-model)
- [Security Caveat](#security-caveat)
- [Limitations](#limitations)
- [Development](#development)

## Requirements

- macOS on Apple Silicon
- macOS Sonoma (14) / Darwin 23 or newer
- Puppet 7.24 through Puppet 8
- Command Line Tools for Xcode

This module does not support Intel Homebrew under `/usr/local` or Linuxbrew.

## How It Works

The module approaches Homebrew in layers:

- The `homebrew` class manages the Homebrew installation itself.
- `package { ... provider => homebrew }` manages formulae and casks.
- `homebrew::tap` manages additional tap repositories.
- `service { ... provider => homebrew }` manages formula services exposed by
  Homebrew through `brew services`.

The package and service providers both resolve the owner of `/opt/homebrew`
and execute in that context. This keeps behavior aligned with how Homebrew
expects to run, while still fitting into Puppet's catalog model.

## Usage

### Typical Catalog Shape

If Puppet should manage Homebrew itself, declare the class and relate it to the
resources that use the Homebrew providers:

```puppet
class { 'homebrew':
  install_user => 'penny',
}

Class['homebrew']
-> Package <| provider == 'homebrew' |>

Class['homebrew']
-> Service <| provider == 'homebrew' |>
```

Setting `install_user` is the most deterministic option, especially when
Puppet runs as a system service or otherwise outside the target user's login
session.

Express any package-to-service ordering directly between the specific
resources that need it, such as `Package['openvpn'] -> Service['openvpn']`.

### Install Or Remove Homebrew

#### Install The Latest Release

```puppet
class { 'homebrew': }
```

#### Install For A Specific User

```puppet
class { 'homebrew':
  install_user => 'penny',
}
```

#### Pin A Homebrew Release

```puppet
class { 'homebrew':
  version => '5.1.0',
}
```

#### Use A Custom Installer Source

```puppet
class { 'homebrew':
  source => 'https://example.test/Homebrew.pkg',
}
```

#### Remove Homebrew

```puppet
class { 'homebrew':
  ensure => 'absent',
}
```

The class follows Homebrew's supported macOS package installation path. It
checks for the Command Line Tools before installation unless
`require_clt => false` is set.

### Manage Packages

Select the provider explicitly on `package` resources that should be managed
through Homebrew.

#### Manage A Formula

```puppet
package { 'tmux':
  ensure   => present,
  provider => homebrew,
}
```

#### Manage A Cask

```puppet
package { 'chatgpt':
  ensure   => latest,
  provider => homebrew,
}
```

#### Disambiguate Formula vs Cask

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

#### Package Behavior

- Supports `ensure => present|installed|latest|absent`
- Reports installed packages through the RAL inventory
- Uses one provider for both formulae and casks
- Forces install and uninstall actions with `--force` so Puppet can recover
  from drifted or partially orphaned Homebrew state

Exact version `ensure` values are not supported.

### Manage Taps

Use `homebrew::tap` to manage additional tap repositories.

#### Add A Tap

```puppet
homebrew::tap { 'puppetlabs/puppet': }
```

#### Add A Tap With A Custom Remote

```puppet
homebrew::tap { 'openvoxproject/openvox':
  source => 'https://github.com/openvoxproject/homebrew-openvox',
}
```

#### Remove A Tap

```puppet
homebrew::tap { 'puppetlabs/puppet':
  ensure => absent,
}
```

Tap resources resolve the Homebrew owner from `install_user` on the declared
`homebrew` class when available, and otherwise from the `homebrew_owner` fact
that inspects `/opt/homebrew`.

### Manage Services

Use `service { ... provider => homebrew }` to manage formula services exposed
through `brew services`.

#### Start And Enable A Service

```puppet
package { 'openvpn':
  ensure   => present,
  provider => homebrew,
}

service { 'openvpn':
  ensure   => running,
  enable   => true,
  provider => homebrew,
}

Package['openvpn'] -> Service['openvpn']
```

#### Keep A Service Stopped But Registered

```puppet
service { 'openvpn':
  ensure   => stopped,
  enable   => true,
  provider => homebrew,
}
```

#### Run A Service Without Registering It

```puppet
service { 'openvpn':
  ensure   => running,
  enable   => false,
  provider => homebrew,
}
```

This mode is supported when Puppet runs as the Homebrew owner. It is not
supported from a root Puppet run on macOS, because `brew services` cannot run
an unregistered service as root.

#### Service Behavior

- Formula services only
- Supports `ensure => running|stopped`
- Supports `enable => true|false`
- Supports refresh and restart behavior
- Validates that the formula actually defines a Homebrew `service`
- Rejects `ensure => running, enable => false` when Puppet runs as `root`

The resource title must be the formula name accepted by `brew services`, not a
launchd label.

## Execution Model

Homebrew expects to run as the owner of `/opt/homebrew`, while Puppet often
runs as `root`. This module follows a consistent model across package, tap, and
service management:

- If Puppet runs as `root`, the providers use the Homebrew owner's environment
  so `HOME`, `USER`, and `LOGNAME` match the Homebrew installation.
- If Puppet runs as the Homebrew owner, commands run unprivileged as that user.
- If Puppet runs as some other user, provider actions fail.

For services, this means:

- A root Puppet run manages system-level `brew services` state.
- A Puppet run as the Homebrew owner manages login-session `brew services`
  state for that user.
- `ensure => running, enable => false` is only supported in the Homebrew
  owner's login-session context. Root runs must use `enable => true` for
  running system services.

## Security Caveat

Homebrew package and cask operations sometimes require behavior that conflicts
with Puppet's usual root execution model.

When the package provider performs a mutating action from a root Puppet run, it
creates a temporary file under `/etc/sudoers.d`, validates it with `visudo`,
runs the Homebrew command as the Homebrew owner, and then removes the file
immediately afterward.

The temporary rule grants the Homebrew owner `NOPASSWD` root access for the
duration of the provider action. This is an intentional compromise to make
Homebrew cask behavior work inside Puppet's desired-state model, and it should
be considered carefully before use in security-sensitive environments.

Tap and service management do not use that temporary sudoers flow.

## Limitations

- Apple Silicon macOS only
- `/opt/homebrew` only
- Package `ensure` supports only `present`, `installed`, `latest`, and
  `absent`
- Tap management supports only `ensure => present|absent` and an optional
  custom source URL
- Ambiguous package names that exist as both formulae and casks require
  explicit `--formula` or `--cask` options
- Service management supports only formulae that define a Homebrew `service`

## Development

Validation for this module should use PDK:

```shell
pdk validate
pdk test unit
```

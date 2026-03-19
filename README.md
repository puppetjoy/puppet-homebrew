# homebrew

## Description

This module ships an opt-in Puppet package provider for Apple Silicon Homebrew
installs rooted at `/opt/homebrew`.

The provider manages Homebrew formulae and casks through Puppet's native
`package` resource while keeping the user-facing model intentionally simple:
use the same provider for both, and only distinguish between them when
Homebrew itself requires it.

## Setup

### Requirements

- macOS on Apple Silicon
- Homebrew installed at `/opt/homebrew`
- Puppet 7.24 through Puppet 8

This module does not support Intel Homebrew under `/usr/local`, Linuxbrew, or
tap management.

### What The Provider Changes

- Runs `brew` as the owner of `/opt/homebrew`
- Supports `ensure => present|installed|latest|absent`
- Reports installed packages through the RAL inventory
- Forces install and uninstall operations with `--force` so Puppet can recover
  from drifted or partially orphaned Homebrew state

## Usage

The provider is opt-in. Specify `provider => homebrew` on package resources
that should be managed through Homebrew.

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
- No tap management
- Ambiguous names that exist as both formulae and casks require explicit
  `--formula` or `--cask` options

## Development

Validation for this module should use PDK:

```shell
pdk validate
pdk test unit
```

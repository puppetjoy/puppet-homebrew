# Changelog

All notable changes to this project will be documented in this file.

## Release 0.1.0

**Features**

- Added the `homebrew` class to install or remove Homebrew through the
  supported macOS package path, with optional release pinning, alternate
  package sources, `install_user`, and a Command Line Tools precheck.
- Added a `homebrew` provider for Puppet's native `package` resource to manage
  Homebrew formulae and casks under `/opt/homebrew`.
- Added the `homebrew::tap` defined type to manage Homebrew taps with
  `ensure => present|absent` and an optional custom remote.
- Added a `homebrew` provider for Puppet's native `service` resource to manage
  formula services through `brew services`.
- Added the `homebrew_owner` and `homebrew_clt_installed` facts, shared
  provider support code, fixture-driven unit coverage, and GitLab CI for
  `pdk validate` and `pdk test unit`.

**Bugfixes**

- Tolerated Homebrew JSON preamble output so provider inventory parsing remains
  stable when `brew` emits progress lines before JSON.
- Corrected root execution handling for package and service operations by
  running commands in the proper Homebrew-owner context.
- Fixed tap guard handling so `homebrew::tap` correctly detects present and
  absent taps when checking `brew tap-info`.
- Set a safe working directory for package, tap, and service execution so
  Homebrew commands do not fail when Puppet starts in an unreadable directory.
- Avoided recursive `/opt/homebrew` removal on uninstall and improved provider
  error reporting to surface Homebrew's primary failure line.

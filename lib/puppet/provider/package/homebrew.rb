# frozen_string_literal: true

require 'puppet/provider/package'
require 'digest'
require 'etc'
require 'json'

Puppet::Type.type(:package).provide :homebrew, parent: Puppet::Provider::Package do
  desc "Package management for Apple Silicon Homebrew installed at `/opt/homebrew`.

    This provider is opt-in and supports the `install_options` and
    `uninstall_options` attributes. Formulae and casks are treated uniformly
    unless Homebrew requires disambiguation, in which case callers should pass
    `--formula` or `--cask` explicitly through the relevant options array."

  confine 'os.name' => :darwin
  confine 'os.architecture' => :arm64
  confine exists: '/opt/homebrew/bin/brew', for_binary: true

  commands brewcmd: '/opt/homebrew/bin/brew'

  has_feature :upgradeable, :install_options, :uninstall_options

  def self.instances
    records = inventory_records(brew_json(['info', '--json=v2', '--installed']))
    duplicates = duplicate_simple_names(records)

    records.map do |record|
      new(
        name: inventory_name_for(record, duplicates),
        ensure: record[:ensure],
        provider: name,
      )
    end
  end

  def self.brew_prefix
    '/opt/homebrew'
  end

  def self.brew_executable
    '/opt/homebrew/bin/brew'
  end

  def self.sudoers_directory
    '/etc/sudoers.d'
  end

  def self.visudo_executable
    '/usr/sbin/visudo'
  end

  def self.execution_path
    '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
  end

  def self.inventory_records(data)
    formula_records(data.fetch('formulae', [])) + cask_records(data.fetch('casks', []))
  end

  def self.formula_records(formulae)
    formulae.map { |formula| build_formula_record(formula) }
  end

  def self.cask_records(casks)
    casks.map { |cask| build_cask_record(cask) }
  end

  def self.build_formula_record(formula)
    installed_versions = Array(formula['installed']).map { |entry| entry['version'] }.compact

    {
      kind: :formula,
      simple_name: formula['name'],
      canonical_name: canonical_formula_name(formula),
      tap: formula['tap'],
      ensure: ensure_value(installed_versions),
      installed: !installed_versions.empty?,
      latest: latest_formula_version(formula),
    }
  end

  def self.build_cask_record(cask)
    installed_version = cask['installed']

    {
      kind: :cask,
      simple_name: cask['token'],
      canonical_name: canonical_cask_name(cask),
      tap: cask['tap'],
      ensure: installed_version || :absent,
      installed: !installed_version.nil?,
      latest: cask['version'],
    }
  end

  def self.ensure_value(versions)
    return :absent if versions.empty?
    return versions.first if versions.length == 1

    versions
  end

  def self.latest_formula_version(formula)
    stable = formula.dig('versions', 'stable')
    revision = formula.fetch('revision', 0).to_i

    return stable if stable.nil? || stable.empty? || revision <= 0

    "#{stable}_#{revision}"
  end

  def self.canonical_formula_name(formula)
    full_name = formula['full_name'] || formula['name']
    tap = formula['tap']

    return full_name if tap.nil? || tap.empty?

    "#{tap}/#{full_name}"
  end

  def self.canonical_cask_name(cask)
    full_token = cask['full_token'] || cask['token']
    tap = cask['tap']

    return full_token if full_token.include?('/')
    return full_token if tap.nil? || tap.empty?

    "#{tap}/#{full_token}"
  end

  def self.duplicate_simple_names(records)
    records.group_by { |record| record[:simple_name] }
           .select { |_name, group| group.length > 1 }
           .keys
  end

  def self.inventory_name_for(record, duplicates)
    return record[:simple_name] unless duplicates.include?(record[:simple_name])

    record[:canonical_name]
  end

  def self.resolve_resource_record(resource)
    package_type = explicit_package_type(resource)

    case package_type
    when :formula
      formula_record_for(resource[:name])
    when :cask
      cask_record_for(resource[:name])
    else
      formula = formula_record_for(resource[:name])
      cask = cask_record_for(resource[:name])

      if formula && cask
        raise Puppet::Error, "Homebrew package '#{resource[:name]}' is ambiguous; pass install_options or uninstall_options with '--formula' or '--cask'"
      end

      formula || cask
    end
  end

  def self.formula_record_for(name)
    @formula_record_cache ||= {}
    return @formula_record_cache[name] if @formula_record_cache.key?(name)

    data = brew_json(['info', '--json=v2', '--formula', name], allow_missing: true)
    record = if data && !data.fetch('formulae', []).empty?
               build_formula_record(data.fetch('formulae').first)
             end

    @formula_record_cache[name] = record
  end

  def self.cask_record_for(name)
    @cask_record_cache ||= {}
    return @cask_record_cache[name] if @cask_record_cache.key?(name)

    data = brew_json(['info', '--json=v2', '--cask', name], allow_missing: true)
    record = if data && !data.fetch('casks', []).empty?
               build_cask_record(data.fetch('casks').first)
             end

    @cask_record_cache[name] = record
  end

  def self.brew_json(arguments, allow_missing: false)
    output = run_brew(arguments, failonfail: false)

    if output.exitstatus != 0
      return nil if allow_missing && missing_package_output?(output)

      raise Puppet::Error, "Homebrew command failed: #{output}"
    end

    parse_brew_json_output(output.to_s)
  rescue JSON::ParserError => e
    raise Puppet::Error, "Homebrew returned invalid JSON for #{arguments.join(' ')}: #{e.message}"
  end

  def self.parse_brew_json_output(output)
    JSON.parse(output)
  rescue JSON::ParserError => original_error
    payload = extract_json_payload(output)
    raise original_error if payload.nil?

    JSON.parse(payload)
  end

  def self.extract_json_payload(output)
    start_index = [output.index('{'), output.index('[')].compact.min
    return nil if start_index.nil?

    end_index = json_document_end(output, start_index)
    return nil if end_index.nil?

    output[start_index..end_index]
  end

  def self.json_document_end(output, start_index)
    stack = []
    in_string = false
    escaped = false

    output.each_char.with_index do |char, index|
      next if index < start_index

      if in_string
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == '"'
          in_string = false
        end

        next
      end

      case char
      when '"'
        in_string = true
      when '{', '['
        stack << char
      when '}'
        return nil unless stack.last == '{'

        stack.pop
        return index if stack.empty?
      when ']'
        return nil unless stack.last == '['

        stack.pop
        return index if stack.empty?
      end
    end

    nil
  end

  def self.missing_package_output?(output)
    normalized_output = output.downcase

    normalized_output.include?('no available formula') ||
      normalized_output.include?('no available cask') ||
      normalized_output.include?('no formulae or casks found') ||
      normalized_output.include?('unavailable: no formula with this name exists') ||
      normalized_output.include?('unavailable: no cask with this name exists')
  end

  def self.run_brew(arguments, failonfail: true, mutating: false, resource: nil)
    owner = brew_owner

    ensure_execution_user!(owner)

    execute_arguments = {
      failonfail: failonfail,
      combine: true,
      uid: owner[:uid],
      gid: owner[:gid],
      custom_environment: brew_environment(owner),
    }

    if mutating && Process.uid.zero?
      with_temporary_sudoers(owner[:name], sudoers_resource_name(resource, arguments.last)) do
        execute([brew_executable] + arguments, execute_arguments)
      end
    else
      execute([brew_executable] + arguments, execute_arguments)
    end
  end

  def self.brew_owner
    @brew_owner ||= begin
      stat = File.stat(brew_prefix)
      entry = Etc.getpwuid(stat.uid)

      {
        uid: stat.uid,
        gid: stat.gid,
        name: entry.name,
        home: entry.dir,
      }
    end
  end

  def self.ensure_execution_user!(owner)
    return if Process.uid.zero? || Process.uid == owner[:uid]

    raise Puppet::Error, "Homebrew provider must run as root or as #{owner[:name]}, the owner of #{brew_prefix}"
  end

  def self.brew_environment(owner)
    {
      'HOME' => owner[:home],
      'USER' => owner[:name],
      'LOGNAME' => owner[:name],
      'PATH' => execution_path,
    }
  end

  def self.with_temporary_sudoers(owner_name, resource_name)
    unless File.executable?(visudo_executable)
      raise Puppet::Error, "Cannot validate temporary sudoers file because #{visudo_executable} is not executable"
    end

    path = sudoers_path(resource_name)

    begin
      File.write(path, sudoers_contents(owner_name))
      File.chmod(0o440, path)
      execute([visudo_executable, '-cf', path], failonfail: true, combine: true)
      yield
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def self.sudoers_path(resource_name)
    digest = Digest::SHA256.hexdigest(resource_name.to_s)[0, 12]
    File.join(sudoers_directory, "puppet-homebrew-#{Process.pid}-#{digest}")
  end

  def self.sudoers_contents(owner_name)
    <<~SUDOERS
      # Managed temporarily by Puppet homebrew provider
      #{owner_name} ALL=(root) NOPASSWD: ALL
    SUDOERS
  end

  def self.sudoers_resource_name(resource, fallback)
    return fallback if resource.nil?

    resource[:name]
  end

  def self.append_force!(arguments)
    return if arguments.include?('--force') || arguments.include?('-f')

    arguments << '--force'
  end

  def self.explicit_package_type(resource)
    types = option_types(resource[:install_options]) + option_types(resource[:uninstall_options])
    types.uniq!

    if types.length > 1
      raise Puppet::Error, "Homebrew package '#{resource[:name]}' cannot specify both formula and cask options"
    end

    types.first
  end

  def self.option_types(options)
    values = Array(options).flat_map do |option|
      option.is_a?(Hash) ? option.keys : option
    end

    values.compact.filter_map do |option|
      case option
      when '--cask', '--casks'
        :cask
      when '--formula', '--formulae'
        :formula
      end
    end
  end

  def query
    record = self.class.resolve_resource_record(@resource)
    return nil unless record&.fetch(:installed)

    {
      name: @resource[:name],
      ensure: record[:ensure],
      provider: self.class.name,
    }
  end

  def latest
    record = self.class.resolve_resource_record(@resource)
    record&.fetch(:latest)
  end

  def install
    validate_requested_ensure!

    arguments = ['install'] + install_options
    self.class.append_force!(arguments)
    arguments << @resource[:name]

    self.class.run_brew(arguments, mutating: true, resource: @resource)
  end

  def update
    arguments = [query ? 'upgrade' : 'install'] + install_options
    self.class.append_force!(arguments)
    arguments << @resource[:name]

    self.class.run_brew(arguments, mutating: true, resource: @resource)
  end

  def uninstall
    arguments = ['uninstall'] + uninstall_options
    self.class.append_force!(arguments)
    arguments << @resource[:name]

    self.class.run_brew(arguments, mutating: true, resource: @resource)
  end

  def install_options
    join_options(@resource[:install_options]) || []
  end

  def uninstall_options
    join_options(@resource[:uninstall_options]) || []
  end

  def validate_requested_ensure!
    should = @resource.should(:ensure)
    return if [:present, :installed].include?(should)

    raise Puppet::Error, 'Homebrew package provider does not support exact version ensure values; use present/installed/latest/absent instead'
  end
end

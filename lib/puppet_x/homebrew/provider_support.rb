# frozen_string_literal: true

require 'etc'
require 'json'

# Puppet extension namespace.
module PuppetX
end

# Homebrew-specific Puppet extension namespace.
module PuppetX::Homebrew
end

# Shared helpers for the Homebrew Puppet providers.
module PuppetX::Homebrew::ProviderSupport
  BREW_PREFIX = '/opt/homebrew'
  BREW_EXECUTABLE = '/opt/homebrew/bin/brew'
  EXECUTION_PATH = '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'

  def brew_prefix
    BREW_PREFIX
  end

  def brew_executable
    BREW_EXECUTABLE
  end

  def execution_path
    EXECUTION_PATH
  end

  def brew_owner
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

  def ensure_execution_user!(owner, provider_label: 'provider')
    return if Process.uid.zero? || Process.uid == owner[:uid]

    raise Puppet::Error,
          "Homebrew #{provider_label} must run as root or as #{owner[:name]}, the owner of #{brew_prefix}"
  end

  def brew_environment(owner)
    {
      'HOME' => owner[:home],
      'USER' => owner[:name],
      'LOGNAME' => owner[:name],
      'PATH' => execution_path,
    }
  end

  def primary_output_line(output)
    lines = output.to_s.each_line.map(&:strip).reject(&:empty?)

    line = lines.find { |entry| entry.start_with?('Error:') } ||
           lines.find { |entry| entry.start_with?('Warning:') } ||
           lines.first

    return nil if line.nil?

    line.sub(%r{\A(?:Error|Warning):\s*}, '')
  end

  def parse_json_output(output, arguments)
    JSON.parse(output)
  rescue JSON::ParserError => original_error
    payload = extract_json_payload(output)
    raise Puppet::Error, "Homebrew returned invalid JSON for #{arguments.join(' ')}: #{original_error.message}" if payload.nil?

    JSON.parse(payload)
  rescue JSON::ParserError => e
    raise Puppet::Error, "Homebrew returned invalid JSON for #{arguments.join(' ')}: #{e.message}"
  end

  def extract_json_payload(output)
    start_index = [output.index('{'), output.index('[')].compact.min
    return nil if start_index.nil?

    end_index = json_document_end(output, start_index)
    return nil if end_index.nil?

    output[start_index..end_index]
  end

  def json_document_end(output, start_index)
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
end

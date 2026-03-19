# frozen_string_literal: true

require 'etc'

Facter.add(:homebrew_owner) do
  confine kernel: 'Darwin'

  setcode do
    prefix = '/opt/homebrew'
    next unless File.directory?(prefix)

    Etc.getpwuid(File.stat(prefix).uid).name
  rescue Errno::ENOENT, Errno::ENOTDIR, Etc::Error
    nil
  end
end

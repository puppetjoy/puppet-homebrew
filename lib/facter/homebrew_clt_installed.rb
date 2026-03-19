Facter.add(:homebrew_clt_installed) do
  setcode do
    File.exist?('/Library/Developer/CommandLineTools/usr/bin/git')
  end
end

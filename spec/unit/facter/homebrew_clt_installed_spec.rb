# frozen_string_literal: true

require 'spec_helper'
require 'facter'

describe 'homebrew_clt_installed fact' do
  let(:fact_path) { File.expand_path('../../../lib/facter/homebrew_clt_installed.rb', __dir__) }
  let(:clt_git_path) { '/Library/Developer/CommandLineTools/usr/bin/git' }

  before(:each) do
    Facter.clear
    load fact_path
    allow(File).to receive(:exist?).and_call_original
  end

  after(:each) do
    Facter.clear
  end

  it 'returns true when the CLT git binary exists' do
    allow(File).to receive(:exist?).with(clt_git_path).and_return(true)

    expect(Facter.value(:homebrew_clt_installed)).to be(true)
  end

  it 'returns false when the CLT git binary is missing' do
    allow(File).to receive(:exist?).with(clt_git_path).and_return(false)

    expect(Facter.value(:homebrew_clt_installed)).to be(false)
  end
end

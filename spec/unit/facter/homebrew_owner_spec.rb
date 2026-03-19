# frozen_string_literal: true

require 'spec_helper'
require 'facter'

describe 'homebrew_owner fact' do
  let(:fact_path) { File.expand_path('../../../lib/facter/homebrew_owner.rb', __dir__) }
  let(:brew_prefix) { '/opt/homebrew' }

  before(:each) do
    Facter.clear
    load fact_path
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:stat).and_call_original
    allow(Etc).to receive(:getpwuid).and_call_original
  end

  after(:each) do
    Facter.clear
  end

  it 'returns the owner of the Homebrew prefix when it exists' do
    stat = instance_double(File::Stat, uid: 1000)
    entry = instance_double(Etc::Passwd, name: 'joy')

    allow(File).to receive(:directory?).with(brew_prefix).and_return(true)
    allow(File).to receive(:stat).with(brew_prefix).and_return(stat)
    allow(Etc).to receive(:getpwuid).with(1000).and_return(entry)

    expect(Facter.value(:homebrew_owner)).to eq('joy')
  end

  it 'returns nil when the Homebrew prefix is missing' do
    allow(File).to receive(:directory?).with(brew_prefix).and_return(false)

    expect(Facter.value(:homebrew_owner)).to be_nil
  end
end

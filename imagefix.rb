#!/usr/bin/env ruby

require 'json'
require "net/http"
require "uri"
require 'open-uri'

require 'zip'
require 'string/similarity'
require 'nokogiri'
require './zip_utils'

vassal_mod = ARGV[0]
image_db_path = "#{File.dirname(__FILE__)}/image-db"

def remote_images_sha()
  github_repo = "ajmath/xwing-card-images"
  github_branch = "master"

  api_base = "https://api.github.com/repos"
  uri = URI.parse("#{api_base}/#{github_repo}/commits/#{github_branch}")
  request = Net::HTTP::Get.new(uri.request_uri)
  request["Accept"] = "application/vnd.github.v3+sha"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  response = http.request(request)
  return nil if response.code != "200"
  return response.body
end

def current_repo_sha()
  begin
    open("#{File.dirname(__FILE__)}/image-db/sha").read
  rescue
    nil
  end
end

def download_repo(sha)
  github_repo = "ajmath/xwing-card-images"
  github_branch = "master"

  temp_file = Tempfile.new('images_zip')
  open(temp_file.path, 'wb') do |file|
    file << open("https://github.com/#{github_repo}/archive/#{github_branch}.zip").read
  end

  FileUtils.rmtree("#{File.dirname(__FILE__)}/image-db")
  FileUtils.mkdir("#{File.dirname(__FILE__)}/image-db")
  ZipFileGenerator.extract_zip(temp_file.path, "#{File.dirname(__FILE__)}/image-db")
  open("#{File.dirname(__FILE__)}/image-db/sha", 'wb') do |f|
    f << sha
  end
end

def load_card_images(image_db_path)
  cards = []
  for f in Dir.glob("#{image_db_path}/images/**/*") do
    next if !f.match(/.*.jpg$/) and !f.match(/.*.png$/)
    f = f.gsub(image_db_path, "")
    split = f.split('/')
    card = {}
    card[:type] = split[2]
    card[:path] = f
    if card[:type] == "pilots"
      card[:faction] = split[3]
      card[:ship] = split[4]
      card[:name] = split[5].gsub(".png", "").gsub(".jpg", "")
    else
      card[:upgrade_type] = split[3]
      card[:name] = split[4].gsub(".png", "").gsub(".jpg", "")
    end
    cards << card
  end
  cards
end

def load_vassal_cards(zip_dir)
  build_file = Nokogiri::XML(File.open("#{zip_dir}/buildFile"))

  vassal_cards = []

  for piece in build_file.xpath("//VASSAL.build.widget.PieceSlot") do
    card = {}
    next if piece.parent["entryName"] == "Images for Cards"
    if piece.content.include?("Pilot Card")
      card[:type] = "pilots"
      card[:ship] = piece.parent["entryName"]
      card[:faction] = piece.parent.parent["entryName"]
      card[:name] = piece["entryName"]
      card[:path] = piece.content.split(';')[12]

      if card[:ship] == "CR90 Corvette" #HACK
        card[:ship] = card[:name]
      end
      vassal_cards << card
    elsif piece.content.include?("Upgrades")
      card[:type] = "upgrades"
      card[:upgrade_type] = piece.parent["entryName"]
      card[:name] = piece["entryName"]
      card[:path] = piece.content.split(';')[16]
      vassal_cards << card
    end
  end
  vassal_cards
end

def find_match(cards, name, type, faction = nil, ship = nil)
  candidates = cards.select { |c| c[:type] == type }
  candidates = cards.select { |c| c[:faction] == faction } if faction
  candidates = cards.select { |c| c[:ship] == ship } if ship
  result = { match: nil, score: -1 }
  for candidate in candidates do
    score = String::Similarity.cosine(candidate[:name], name)
    result = { match: candidate, score: score } if score > result[:score]
  end
  result
end

def normalize_vassal_name(f)
  f.gsub(/[^a-zA-Z0-9]/, "").downcase
end

def is_excluded(name)
  ["firstorderback", "resistanceback", "back",
    "imperialback", "rebelback", "scumback"].include? name or name.match(/.*crippled$/)
end

def get_faction(vassal_pilot)
  if vassal_pilot[:faction].match(/.*scum.*/i)
    "scum"
  elsif vassal_pilot[:faction].match(/.*imperial.*/i)
    "imperial"
  elsif vassal_pilot[:faction].match(/.*rebel.*/i)
    "rebels"
  else
    nil
  end
end

def match(target, candidates)
  result = { match: nil, score: -1 }
  for candidate in candidates
    score = String::Similarity.cosine(candidate, target)
    result = { match: candidate, score: score } if score > result[:score]
  end
  result
end

def match_ship(vassal_pilot, faction, cards, overrides)
  vassal_ship_name = normalize_vassal_name(vassal_pilot[:ship])
  if overrides["ship"][vassal_ship_name]
    return { match: overrides["ship"][vassal_ship_name].to_s, score: 100 }
  end
  ships = cards.select { |c| c[:faction] == faction }.collect { |c| c[:ship] }.uniq
  match(vassal_ship_name, ships)
end

def match_upgrade_type(vassal_upgrade, cards, overrides)
  vassal_upgrade_type = normalize_vassal_name(vassal_upgrade[:upgrade_type])
  if overrides["upgrade_type"][vassal_upgrade_type]
    return { match: overrides["upgrade_type"][vassal_upgrade_type].to_s, score: 100 }
  end
  upgrade_types = cards.select { |c| c[:type] == "upgrades" }.collect {|c| c[:upgrade_type]}.uniq
  match(vassal_upgrade_type, upgrade_types)
end

def match_upgrade_card(vassal_upgrade, cards, overrides)
  upgrade_type = match_upgrade_type(vassal_upgrade, cards, overrides)[:match]
  vassal_name = normalize_vassal_name(vassal_upgrade[:name])
  candidates = cards.select { |c| c[:upgrade_type] == upgrade_type }
  match = {}
  if overrides["upgrade"][vassal_name]
    match = { match: overrides["upgrade"][vassal_name].to_s, score: 100 }
  else
    names = candidates.collect{|c| c[:name] }.uniq
    match = match(vassal_name, names)
  end
  {
    match: candidates.select { |c| c[:name] == match[:match] }[0],
    score: match[:score]
  }
end

def match_pilot_card(vassal_pilot, cards, overrides)
  faction = get_faction(vassal_pilot)
  ship = match_ship(vassal_pilot, faction, cards, overrides)[:match]
  candidates = cards.select { |c| c[:faction] == faction and c[:ship] == ship}
  match = {}
  vassal_name = normalize_vassal_name(vassal_pilot[:name])
  if overrides["pilot_name"][vassal_name]
    match = { match: overrides["pilot_name"][vassal_name].to_s, score: 100 }
  else
    names = candidates.collect{|c| c[:name] }.uniq
    match = match(vassal_name, names)
  end
  {
    match: candidates.select { |c| c[:name] == match[:match] }[0],
    score: match[:score]
  }
end

def card_to_s(card)
  if card[:type] == "pilots"
    return "#{card[:faction]}/#{card[:ship]}/#{card[:name]}"
  end
  "#{card[:upgrade_type]}/#{card[:name]}"
end

def copy_match(image_db_path, zip_dir, vassal_card, match)
  FileUtils.copy("#{image_db_path}/#{match[:path]}", "#{zip_dir}/images/#{vassal_card[:path]}")
end

#######################################

remote_sha = remote_images_sha
if remote_sha != current_repo_sha
  puts "Downloading new version of xwing-card-images"
  download_repo(remote_sha)
else
  puts "xwing-card-images up to date"
end

overrides = JSON.parse(File.read("#{File.dirname(__FILE__)}/overrides.json"))

zip_dir = Dir.mktmpdir("#{File.basename(vassal_mod)}.dir")
ZipFileGenerator.extract_zip(vassal_mod, zip_dir)

cards = load_card_images(image_db_path)
vassal_cards = load_vassal_cards(zip_dir)

for vassal_card in vassal_cards do
  match = nil
  if vassal_card[:type] == "pilots"
    match = match_pilot_card(vassal_card, cards, overrides)
  end

  if vassal_card[:type] == "upgrades"
    match = match_upgrade_card(vassal_card, cards, overrides)
  end


  if match[:score] < 1.0
    puts "Low match found: #{match[:score]}: #{card_to_s(vassal_card)} -> #{card_to_s(match[:match])}"
    puts "Accept ? (y/n)"
    response = STDIN.gets.chomp
    if response == "y"
      copy_match(image_db_path, zip_dir, vassal_card, match[:match])
    end
  end

  if match[:score] == 1.0
    copy_match(image_db_path, zip_dir, vassal_card, match[:match])
  end
end

new_vmod_file = vassal_mod.gsub(/\.vmod$/, ".imagefix.vmod")

if File.exist? new_vmod_file
  puts "Overrwrite existing mod ? (y/n)"
  response = STDIN.gets.chomp
  if response == "y"
    new_vmod_file = vassal_mod
  end
end

FileUtils.rm new_vmod_file

zipgen = ZipFileGenerator.new(zip_dir, new_vmod_file)
zipgen.write()

puts "Wrote new mod to #{new_vmod_file}"

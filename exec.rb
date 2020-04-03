#!/usr/bin/env ruby
require 'open3'

#TODO may need to set this dynamically
POWERCAP_ROOT_DIR = '/sys/devices/virtual/powercap'

#looks for the provided option 'target_opt', return its value if it's in key-value format
#   else returning true if found or nil if not
#only the first match is considered, prioritising those with values
def find_option(opts_arr, target_opt)
  match_data = nil
  if opts_arr.find { |opt| match_data = opt.match(/^--?#{target_opt}=(\S+)$/) }
    return match_data[1]
  elsif opts_arr.find { |opt| opt =~ /^--?#{target_opt}$/ }
    return true
  else
    return nil
  end
end

def read_first_line(file)
  `head -n 1 #{file}`.strip
end

def find_zone_name(dir)
  cur_dir = dir
  name_str = ''
  while File.dirname(cur_dir) != POWERCAP_ROOT_DIR do
    name_file = File.join(cur_dir, 'name')
    if File.file?(name_file)
      name_str = " --> " + read_first_line(name_file) + name_str
    end
    cur_dir = File.dirname(cur_dir)
  end
  name_str = File.basename(cur_dir) + name_str
end

#returns a list of hashes containing info on each of this node's powercap zones
def get_zone_info
	zone_dirs = Dir.glob(File.join(POWERCAP_ROOT_DIR, '**', '*energy_uj')).map! do |file|
		File.dirname(file)
	end
	zone_info = []
	zone_dirs.each do |dir|
		info_hash = {}
		info_hash['path'] = dir
		info_hash['name'] = find_zone_name(dir)
		#info_hash['starting_energy'] = read_first_line(File.join(dir, 'energy_uj'))
		zone_info << info_hash
	end
	zone_info
end

def read_energy(zones, tag)
  zones.each do |zone|
    zone[tag] = read_first_line(File.join(zone['path'], 'energy_uj'))
  end
end

#treat first argument not starting with a hyphen as the begining of the task
first_cmd = ARGV.index{ |arg| !arg.start_with?('-') }
if first_cmd
  opts_arr, task_arr = ARGV.slice(0, first_cmd), ARGV.slice(first_cmd, ARGV.length)
else
  opts_arr = ARGV
  task_arr = []
end

node = ENV['SLURMD_NODENAME']

zones = get_zone_info
read_energy(zones, "starting_energy")

stdout, stderr, status = Open3.capture3(task_arr.join(' '))
puts stdout.empty? ? stderr : stdout

read_energy(zones, "finishing_energy")
pp zones

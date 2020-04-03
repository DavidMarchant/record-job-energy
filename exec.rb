#!/usr/bin/env ruby
require 'open3'
require 'yaml'

#TODO test with ruby==2.0

#TODO may need to set this dynamically
POWERCAP_ROOT_DIR = '/sys/devices/virtual/powercap'
EnergyRecordError = Class.new(RuntimeError)

def get_env_var(var, error = true)
  if ENV[var]
    return ENV[var]
  else
    if error
      raise EnergyRecordError, "ERROR - environment variable '#{var}' not found - aborting"
    else
      return nil
    end
  end
end

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

#take as input zone information in form output from get_zone_info
def read_energy(zones, tag)
  zones.each do |zone|
    zone[tag] = read_first_line(File.join(zone['path'], 'energy_uj'))
  end
  zones
end

#treat first argument not starting with a hyphen as the begining of the task
first_cmd = ARGV.index{ |arg| !arg.start_with?('-') }
if first_cmd
  opts_arr, task_arr = ARGV.slice(0, first_cmd), ARGV.slice(first_cmd, ARGV.length)
else
  opts_arr, task_arr = ARGV, []
end

job_id = get_env_var('SLURM_JOB_ID', error = false) || get_env_var('SLURM_JOBID')
node = get_env_var('SLURMD_NODENAME')
proc_id = get_env_var('SLURM_PROCID')
#NOTE: should i get this info from the system? the energy readings are from the
#   system after all & this can be altered in slurm conf. edge case.
num_cores = get_env_var('SLURM_CPUS_ON_NODE')
#NOTE: in slurm vocab, 'CPUS' usually (& in this case) actually refers to cores
cpus_per_task = get_env_var('SLURM_CPUS_PER_TASK', error = false) || 0

#TODO extract the default config behaviour
#NOTE: SLURM_SUBMIT_DIR - The directory from which srun was invoked or, if applicable, the directory specified by the -D, --chdir option
#__dir__ can only be used for ruby >= 2.0 but  doesn't change if chdir is called
top_directory = find_option(opts_arr, /d|directory/) || File.join(__dir__, 'record-job-energy')
#TODO duplicate code
begin
  Dir.mkdir(top_directory) unless Dir.exists?(top_directory)
rescue SystemCallError
  raise EnergyRecordError, "Error while creating directory #{top_directory} - aborting"
end
out_directory = File.join(top_directory, job_id)
begin
  Dir.mkdir(out_directory) unless Dir.exists?(out_directory)
rescue SystemCallError
  raise EnergyRecordError, "Error while creating directory #{out_directory} - aborting"
end
out_file = File.join(out_directory, proc_id)

zones = get_zone_info

read_energy(zones, "starting_energy")
#TODO capture errors from this, do we crash out?
stdout, stderr, status = Open3.capture3(task_arr.join(' '))
read_energy(zones, "finishing_energy")

puts stdout.empty? ? stderr : stdout

yaml_zones = zones.to_yaml
File.open(out_file, 'w') { |f| f.write(yaml_zones) }

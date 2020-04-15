#!/usr/bin/env ruby
require 'open3'
require 'yaml'

#TODO test with ruby==2.0

EnergyRecordError = Class.new(RuntimeError)

#TODO may need to set this dynamically
POWERCAP_ROOT_DIR = '/sys/devices/virtual/powercap'
DEFAULTS = {out_directory: File.join(__dir__, 'record-job-energy-data'),
            timeout: 600,
           }

def get_env_var(var, error = true)
  if ENV[var]
    return ENV[var]
  else
    if error
      cancel_job("environment variable '#{var}' not found - aborting")
    else
      return nil
    end
  end
end

def get_job_id(error = true)
  (get_env_var('SLURM_JOB_ID', error_=false) || get_env_var('SLURM_JOBID', error_=error)).to_i
end

def cancel_job(message = nil, proc_id = nil)
  #NOTE: need to not crash if job_id unavailable as an infinite loop is possible between
  #      this method and get_env_var
  job_id = get_job_id(error = false)
  Open3.capture3("scancel #{job_id}") if job_id
  message = if message and proc_id
              "Error in process #{proc_id} - #{message}"
            elsif message
              "Error - #{message}"
            end
  raise EnergyRecordError, message
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
  name_arr = []
  while File.dirname(cur_dir) != POWERCAP_ROOT_DIR do
    name_file = File.join(cur_dir, 'name')
    if File.file?(name_file)
      name_arr.unshift(read_first_line(name_file))
    end
    cur_dir = File.dirname(cur_dir)
  end
  name_arr.unshift(File.basename(cur_dir))
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
		zone_info << info_hash
	end
	zone_info
end

#take as input zone information in form output from get_zone_info
def read_energy(zones, tag)
  zones.each do |zone|
    zone[tag] = read_first_line(File.join(zone['path'], 'energy_uj')).to_i
  end
  zones
end

if get_env_var('SLURM_STEP_ID', error = false).nil?
  cancel_job("run this executable only as part of a Slurm job step, using srun")
end

#treat first argument not starting with a hyphen as the begining of the task
first_cmd = ARGV.index{ |arg| !arg.start_with?('-') }
if first_cmd
  opts_arr, task_arr = ARGV.slice(0, first_cmd), ARGV.slice(first_cmd, ARGV.length)
else
  opts_arr, task_arr = ARGV, []
end

proc_id = get_env_var('SLURM_PROCID').to_i

if find_option(opts_arr, 'help')
  if proc_id == 0
    #TODO update as progress proceeds
    puts <<-help_str
RECORD-JOB-ENERGY HELP
  This script should be executed as:
      PARALLEL_CMD [PARALLEL_CMD_OPTS] exec.rb [OPTS] PARALLEL_TASK [PARALLEL_TASK_OPTS]
    Where PARALLEL_CMD is srun.
  Options for this script include:
    [-d,--directory]=DIR
      Sets the desired output directory to DIR. Default is:
        #{DEFAULTS[:out_directory]}
    [-t,--timeout]=TIMEOUT
      Sets the maximum time the root process will wait for the other processes to complete
      execution, after the root process has finished its execution. Value is in seconds,
      default value is #{DEFAULTS[:timeout]}.
    --help
      Display this message and exit
    help_str
  end
  exit 0
end

cancel_job("no task provided - aborting", proc_id) if task_arr.empty?

#TODO there is a per step version of most of these options(as opposed to per job?)
#     may be best to swap
job_id = get_job_id
node = get_env_var('SLURMD_NODENAME')
num_procs = get_env_var('SLURM_NTASKS').to_i
#NOTE: this value is retreived from the system as there are slurm configuration
#   options that obfuscate the true properties of nodes to slurm processes,
#   which should be bypassed when analysing the system energy consumpton.
num_cores, _stderr, _status = Open3.capture3("nproc")
num_cores = num_cores.strip.to_i
#NOTE: in slurm vocab, 'CPUS' usually (& in this case) actually refers to cores
cpus_per_task = (get_env_var('SLURM_CPUS_PER_TASK', error = false) || 1).to_i

#NOTE: could use SLURM_LAUNCH_NODE_IPADDR to send data back to the launching node rather than use
#     the flesystem. This can avoid issues with distributed filesystem, access rights, etc.
#NOTE: SLURM_SUBMIT_DIR - The directory from which srun was invoked or, if applicable, the directory specified by the -D, --chdir option
#__dir__ can only be used for ruby >= 2.0 but  doesn't change if chdir is called
top_directory = find_option(opts_arr, /d|directory/) || DEFAULTS[:out_directory]
out_directory = File.join(top_directory, job_id.to_s)
comms_file = File.join(out_directory, "comms_file")
out_file_path = File.join(out_directory, proc_id.to_s)

if proc_id == 0
  #TODO duplicate code
  begin
    Dir.mkdir(top_directory) unless Dir.exists?(top_directory)
  rescue SystemCallError
    cancel_job("Error while creating directory #{top_directory} - aborting", proc_id)
  end
  begin
    Dir.mkdir(out_directory) unless Dir.exists?(out_directory)
  rescue SystemCallError
    cancel_job("Error while creating directory #{out_directory} - aborting", proc_id)
  end
end

zones = get_zone_info

read_energy(zones, "starting_energy")
#TODO capture errors from this, do we crash out?
stdout, stderr, status = Open3.capture3(task_arr.join(' '))
read_energy(zones, "finishing_energy")

print stdout.empty? ? stderr : stdout

proc_data = {'node' => node,
             'num_cores' => num_cores,
             'job_id' => job_id,
             'proc_id' => proc_id,
             'cpus_per_task' => cpus_per_task,
             'zones' => zones}

yaml_proc_data = proc_data.to_yaml
File.open(out_file_path, 'w') { |f| f.write(yaml_proc_data) }


#NOTE: this is done as a system call to make use of any distributed filesystem's
#   concurrency control
_, _, _ = Open3.capture3("echo 'process #{proc_id} completed' >> #{comms_file}")

if proc_id == 0
  t1 = Time.now
  time_limit = find_option(opts_arr, /t|timeout/) || 600
  #NOTE: hung here with a local /opt/slurm/bin/sbatch -n 2 run-exec.sh for some reason
  # only got 1 output file & so the line count did nae work
  while true
    if File.open(comms_file,"r").readlines.count == num_procs
      break
    #TODO start this recording from initial execution?
    elsif Time.now - t1 > time_limit
      cancel_job("timeout waiting for processes to complete", proc_id)
    end
    sleep 1
  end
  per_node_data = {}
  Dir.glob(File.join(out_directory, '*')).each do |file|
    next if file == comms_file
    proc_data = YAML.load(File.read(file))
    node_ = proc_data['node']
    node_proportion = (1.0/proc_data['num_cores'])*proc_data['cpus_per_task']

    per_node_data[node_] ||= {}
    per_node_data[node_]['num_cores'] = proc_data['num_cores']
    per_node_data[node_]['cores_used'] ||= 0
    per_node_data[node_]['cores_used'] += proc_data['cpus_per_task']
    per_node_data[node_]['zones'] ||= {}

    proc_data['zones'].each do |zone|
      zone_name_ = zone['name'].join('-->')
      change = (zone['finishing_energy']-zone['starting_energy'])*node_proportion
      per_node_data[node_]['zones'][zone_name_] ||= 0
      per_node_data[node_]['zones'][zone_name_] += change
    end
  end
  yaml_per_node_data = per_node_data.to_yaml
  totals_out_file_path = File.join(out_directory, "totalled_data")
  File.open(totals_out_file_path, 'w') { |f| f.write(yaml_per_node_data) }
end

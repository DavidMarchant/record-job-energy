#!/usr/bin/env ruby

require 'fileutils'
require 'open3'
require 'rubygems'
require 'yaml'

EnergyRecordError = Class.new(RuntimeError)

POWERCAP_ROOT_DIR = '/sys/devices/virtual/powercap'
DEFAULTS = {out_directory: File.join(__dir__, 'record-job-energy-data'),
            timeout: 600,
           }
HELP_STR = <<-help_str
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
  job_id = get_env_var('SLURM_JOB_ID', error_ = false)
  job_id = get_env_var('SLURM_JOBID', error_ = error) unless job_id
  job_id.to_i
end

def get_step_id(job_directory, error = true)
  unless step_id = get_env_var('SLURM_STEP_ID', error = false)
    #NOTE: known issue where, under OpenMPI, the root process of mpiexec will not
    #   receive some environment variables that others will. In this case the
    #   value of the step must be discerned from the size of the job's directory
    if $running_mode == :open_mpi
      #NOTE: -2 because '.' and '..' are present in all directories
      step_id = Dir.exist?(job_directory) ? Dir.entries(job_directory).length-2 : 0
    else
      step_id = get_env_var('SLURM_STEP_ID', error_ = error)
    end
  end
  step_id.to_i
end

def cancel_job(message = nil, proc_id = nil)
  job_id = get_job_id(error = false)
  Open3.capture3("scancel #{job_id}") if job_id
  message = if message and proc_id
              "Record Job Energy error in process #{proc_id} - #{message}"
            elsif message
              "Record Job Energy error - #{message}"
            end
  raise EnergyRecordError, message
end

def get_from_shell_cmd(cmd, proc_id)
  stdout, stderr, status = Open3.capture3(cmd)
  if not status.success?
    cancel_job("error executing command '#{cmd}' - #{stderr}", proc_id)
  end
  return stdout.strip!
end

#looks for the provided option 'target_opt', return its value if it's in
#   key-value format else returning true if found or nil if not
#only the first match is considered, prioritising those with values
def find_option(target_opt)
  match_data = nil
  if $opts_arr.find { |opt| match_data = opt.match(/^--?#{target_opt}=(\S+)$/) }
    return match_data[1]
  elsif $opts_arr.find { |opt| opt =~ /^--?#{target_opt}$/ }
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
	zone_dirs = Dir.glob(File.join(POWERCAP_ROOT_DIR, '**', '*energy_uj'))
  zone_dirs.map! do |file|
		File.dirname(file)
	end
	zone_info = []
	zone_dirs.each do |dir|
		info_hash = {}
		info_hash[:path] = dir
		info_hash[:name] = find_zone_name(dir)
		zone_info << info_hash
	end
	zone_info
end

#take as input zone information in form output from get_zone_info
def read_energy(zones, tag)
  zones.each do |zone|
    energy = read_first_line(File.join(zone[:path], 'energy_uj')).to_i
    zone[tag.to_sym] = {time: Time.now, energy: energy, unit: 'uj'}
  end
  zones
end

def create_directory(directory, proc_id)
  begin
    FileUtils.mkdir_p(directory) unless Dir.exists?(directory)
  rescue SystemCallError
    cancel_job("Error while creating directory #{directory} - aborting", proc_id)
  end
end

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.0.0')
  puts "Record Job Energy WARNING - using Ruby version #{RUBY_VERSION}, recommended is 2.0.0 or later"
end

#treat first argument not starting with a hyphen as the begining of the task
first_cmd = ARGV.index{ |arg| !arg.start_with?('-') }
if first_cmd
  $opts_arr, $task_arr = ARGV.slice(0, first_cmd), ARGV.slice(first_cmd, ARGV.length)
else
  $opts_arr, $task_arr = ARGV, []
end

if get_env_var('SLURM_PROCID', error = false).nil?
  cancel_job("run this executable only as part of a Slurm job, using srun or mpiexec")
end

if proc_id = get_env_var('PMI_RANK', error = false)
  $running_mode = :intel_mpi
  num_procs = get_env_var('PMI_SIZE').to_i
elsif proc_id = get_env_var('OMPI_COMM_WORLD_RANK', error = false)
  $running_mode = :open_mpi
  num_procs = get_env_var('OMPI_COMM_WORLD_SIZE').to_i
#NOTE: check presence of a step ID to ensure execution is within srun
#   not only sbatch
elsif get_env_var('SLURM_STEP_ID', error = false)
  proc_id = get_env_var('SLURM_PROCID', error = false)
  $running_mode = :srun
  num_procs = get_env_var('SLURM_NTASKS').to_i
else
  cancel_job("run this executable only as part of a Slurm job, using srun or mpiexec")
end
proc_id = proc_id.to_i

if find_option('help')
  if proc_id == 0
    puts HELP_STR
  end
  exit 0
end

job_id = get_job_id
top_directory = find_option(/d|directory/) || DEFAULTS[:out_directory]
job_directory = File.join(top_directory, job_id.to_s)
step_id = get_step_id(job_directory, error = true)
out_directory = File.join(job_directory, step_id.to_s)

cancel_job("no task provided - aborting", proc_id) if $task_arr.empty?

node = get_from_shell_cmd('hostname', proc_id)
#NOTE: this value is retreived from the system as there are slurm configuration
#   options that obfuscate the true properties of nodes to slurm processes.
#   This obfuscation would confuse the data conclusions.
num_cores = get_from_shell_cmd('nproc --all', proc_id).to_i
#NOTE: in slurm vocab, 'CPUS' usually (& in this case) actually refers to cores
cpus_per_task = (get_env_var('SLURM_CPUS_PER_TASK', error = false) || 1).to_i

if proc_id == 0
  create_directory(out_directory, proc_id)
  step_info_path = File.join(out_directory, "step_info")
  step_info = { job_id: job_id,
               step_id: step_id,
               task: $task_arr.join(' '),
               parallel_cmd: $running_mode.to_s,
               num_procs: num_procs,
             }
  yaml_step_info = step_info.to_yaml
  File.open(step_info_path, 'w') { |f| f.write(yaml_step_info) }
end

zones = get_zone_info

read_energy(zones, :starting_energy)
Open3.popen2e($task_arr.join(' ')) do |stdin, stdout_and_stderr, wait_thr|
  while line = stdout_and_stderr.gets do
    puts line
  end
  unless wait_thr.value.success?
    cancel_job("task #{$task_arr.join(' ')} failed", proc_id)
  end
end
read_energy(zones, :finishing_energy)

proc_data = {node: node,
             num_cores: num_cores,
             job_id: job_id,
             step_id: step_id,
             proc_id: proc_id,
             cpus_per_task: cpus_per_task,
             zones: zones}

out_file_path = File.join(out_directory, proc_id.to_s)
yaml_proc_data = proc_data.to_yaml
File.open(out_file_path, 'w') { |f| f.write(yaml_proc_data) }

if proc_id == 0
  t1 = Time.now
  time_limit = find_option(/t|timeout/)
  time_limit = DEFAULTS[:timeout] if time_limit.nil? or time_limit == true
  while true
    process_files = Dir.entries(out_directory).select do |file|
      file.to_i.to_s == file
    end
    if process_files.length == num_procs
      break
    elsif Time.now - t1 > time_limit.to_i
      cancel_job("timeout waiting for processes to complete", proc_id)
    end
    sleep 1
  end
  per_node_data = {total: 0, units: 'Joules'}
  Dir.glob(File.join(out_directory, '*')).each do |file|
    #only process files with a proc id as a name
    next unless File.basename(file).to_i.to_s == File.basename(file)
    proc_data = YAML.load_file(file)
    node_ = proc_data[:node]
    node_proportion = (1.0/proc_data[:num_cores])*proc_data[:cpus_per_task]

    #NOTE Time.at((2**31)-1) gives the maximum possible time value
    #     so all others will be lesser
    per_node_data[node_] ||= {start_time: Time.at(max_time = (2**31)-1),
                              finish_time: Time.at(0)
                             }
    per_node_data[node_][:num_cores] = proc_data[:num_cores]
    per_node_data[node_][:num_procs] ||= 0
    per_node_data[node_][:num_procs] += 1
    per_node_data[node_][:cores_used] ||= 0
    per_node_data[node_][:cores_used] += proc_data[:cpus_per_task]
    per_node_data[node_][:zones] ||= {}

    proc_data[:zones].each do |zone|
      zone_name_ = zone[:name].join('-->')
      change = (zone[:finishing_energy][:energy]-zone[:starting_energy][:energy])
      change = change.to_f / 1000000 if zone[:unit] = 'uj'
      process_change = change*node_proportion
      process_change = process_change.round(7)
      per_node_data[node_][:zones][zone_name_] ||= 0
      per_node_data[node_][:zones][zone_name_] += process_change
      per_node_data[node_][:node_total] ||= 0
      per_node_data[node_][:node_total] += process_change

      if per_node_data[node_][:start_time] > zone[:starting_energy][:time]
        per_node_data[node_][:start_time] = zone[:starting_energy][:time]
      end
      if per_node_data[node_][:finish_time] < zone[:finishing_energy][:time]
        per_node_data[node_][:finish_time] = zone[:finishing_energy][:time]
      end
      per_node_data[:total] += process_change
    end
  end
  per_node_data[:step_info] = step_info
  yaml_per_node_data = per_node_data.to_yaml
  totals_out_file_path = File.join(out_directory, "totalled_data")
  File.open(totals_out_file_path, 'w') { |f| f.write(yaml_per_node_data) }
end

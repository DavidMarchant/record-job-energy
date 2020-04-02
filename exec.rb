#!/usr/bin/env ruby
require 'open3'

#treat first argument not starting with a hyphen as the begining of the task
first_cmd = ARGV.index{ |arg| !arg.start_with?('-') }
if first_cmd
  opts_arr, task_arr = ARGV.slice(0, first_cmd), ARGV.slice(first_cmd, ARGV.length)
else
  opts_arr = ARGV
  task_arr = []
end

node = ENV['SLURMD_NODENAME']

stdout, stderr, status = Open3.capture3(task_arr.join(' '))
stdout.empty? ? puts stderr : puts stdout

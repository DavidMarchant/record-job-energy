# record-job-energy

## Overview

User-level utility for monitoring energy consumption on HPC clusters via Slurm.
Utilises the Linux-standard [powercap framework](https://www.kernel.org/doc/Documentation/power/powercap/powercap.txt) to interface with kernel devices
to retrieve energy information without requiring superuser privileges. Currently
has only been tested on RHEL-derivative RAPL systems.

## Installation

Requires Ruby version >= 2.0.0.

`curl https://raw.githubusercontent.com/DavidMarchant/record-job-energy/master/record-job-energy.rb > record-job-energy.rb`

## Use

PARALLEL_CMD [OPTIONS] record-job-energy.rb [OPTIONS] TASK [OPTIONS]

Where PARALLEL_CMD is srun or mpirun/mpiexec where the MPI command is ran
within an sbatch or salloc Slurm allocation. Only Intel MPI and OpenMPI MPI
implementations have been tested.

### Options

-t/--timeout=INTEGER
  The amount of time, in seconds, the root process will wait for the other
  processes to return before assuming that it has silently failed.
  Default is 600
-d/--directory=PATH
  The directory to use as the top level of the data store.
  Default is script_directory/record-job-energy-data
--help
  Displays a help string and exits.

### Output

Output utilises as parallel file system. Your user must have access with write
permissions. Data is stored by job and by job step in the specified directory.
Note that the total fields in the 'totalled_data' file will not be accurate to
the total energy consumed, it will be an over estimate as powercap zones often
overlap. Instead it is a total of the zones' values and is intended for
comparison.

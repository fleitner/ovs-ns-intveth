#!/bin/bash
# Orig author: Eric Dumazet <eric.dumazet@gmail.com>
# Version 1.0.0 (by brouer@redhat.com and dborkman@redhat.com)
#
# This script starts several parallel netperf's and sums the results.
#
# Usage: super_netperf NUM_PARALLEL NETPERF_ARGS
#
#   NUM_PARALLEL - specifies number of parallel netperf's to start
#   NETPERF_ARGS - The rest of args are passed directly to netperf
#
#  Depends on a netperf version with option "-s" support, as this
#  script uses this option, to wait 2 sec before starting the test run.
#
# Awk help:
#  NF gives you the total number of fields in a record/line

run_netperf() {
    loops=$1
    shift
    for ((i=0; i<loops; i++)); do
        netperf -s 2 $@ | awk '/Min/{
            if (!once) {
                print;
                once=1;
            }
        }
        {
            if (NR == 6)
                save = $NF
            else if (NR==7) {
                if (NF > 0)
                    print $NF
                else
                    print save
            } else if (NR==11) {
                print $0
            }
        }' &
    done
    wait
    return 0
}

run_netperf $@ | awk '{if (NF==7) {print $0; next}} {sum += $1} END {print sum}'

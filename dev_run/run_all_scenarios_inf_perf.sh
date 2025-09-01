#epps=(baseline load estimate)
#epps=(estimate)

# Scheduler experiment 2
#epps=(sched_random shed_load_kvcache_util sched_estimate sched_load_dominant sched_estimate_dominant)
#workloads=(sched_synthetic)

# Scheduler - new load scorer
# epps=(sched_random shed_active_req_kvcache_util)
# workloads=(sched_synthetic)

# Scheduler - load only (GIE impl)
epps=(sched_random shed_load_only)
workloads=(sched_synthetic)


#workloads=(shared_prefix_synthetic_exp1 shared_prefix_synthetic_exp2 shared_prefix_synthetic_exp3)

#short test
#epps=(shed_active_req_kvcache_util)
#workloads=(sched_synthetic_short)

for epp in "${epps[@]}"; do 
    for workload in "${workloads[@]}"; do 
        util/run_scenario.sh -w $workload -e $epp -c $(realpath ./inf_perf_env.sh) -l inference-perf; 
    done; 
done

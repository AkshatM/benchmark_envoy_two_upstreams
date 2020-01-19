#!/bin/bash

set -x 
apt-get update

install_system_dependencies() {
    curl -sL https://deb.nodesource.com/setup_10.x | bash -
    apt-get install -y git python nodejs cpuset linux-tools-common linux-tools-generic linux-tools-$(uname -r) tuned jq
    npm install -g forever
}

install_client() {
    curl -L https://raw.githubusercontent.com/AkshatM/bullseye/master/bullseye > /usr/bin/bullseye
    chmod +x /usr/bin/bullseye
}

install_envoy_and_bazel_dependencies() {
    # install Docker so we can grab Envoy
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
}

cleanup_envoy_and_bazel_dependencies() {
    # remove and destroy Docker altogether
    apt-get purge -y docker-engine docker docker.io docker-ce
    apt-get autoremove -y
    rm -rf /var/lib/docker /etc/docker
}

download_and_build_envoy() {
   
   set -e
   install_envoy_and_bazel_dependencies

   # pull official containing a version of Envoy 1.11.1 with debug symbols still in the binary.
   # Though built in an alpine environment, I've tested this still works on Ubuntu. 
   docker pull envoyproxy/envoy-alpine-debug:v1.11.1
   docker run --rm --entrypoint cat envoyproxy/envoy-alpine-debug /usr/local/bin/envoy > /root/baseline_envoy
   chmod +x /root/baseline_envoy

   cleanup_envoy_and_bazel_dependencies
   set +e
   echo "Build finished!"
}

install_system_dependencies
install_client
download_and_build_envoy

sysctl -w net.ipv4.tcp_low_latency=1
tuned-adm profile network-latency
# kernel module for power management is not enabled on DigitalOceans machines
#for ((i=0; i < 4; i++)); do 
#	echo performance > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor
#done

set -e
# created by docker installation, remove
cset set --destroy docker 
# generate dedicated CPU sets for certain tasks
cset set --cpu=5,6 --set=node --cpu_exclusive 
cset set --cpu=1,2,3,4 --set=envoy --cpu_exclusive
cset set --cpu=7 --set=client --cpu_exclusive
cset set --cpu=0 --set=system --cpu_exclusive
# move all running threads to different CPUs
cset proc --move --kthread --fromset=root --toset=system --force


rates=(100)
concurrencies=(4)
durations=(10)
readarray -t header_profiles < /root/header_profiles 
readarray -t envoy_config_types < /root/envoy_configs

for rate in ${rates[*]}; do
    for concurrency in ${concurrencies[*]}; do
	for duration in ${durations[*]}; do
	    for header_profile in ${header_profiles[*]}; do
	        for config_type in ${envoy_config_types[*]}; do
                    mkdir -p /root/results/"${header_profile}"/"${rate}"/"${concurrency}"/"${duration}"/"${config_type}"
		done
                mkdir -p /root/results/"${header_profile}"/"${rate}"/"${concurrency}"/"${duration}"/none
            done
        done
    done
done

# we use cpuset to run these processes, but cpuset is dumb and can't parse bash redirection operators
# as belonging to the root command, nor will it accept a string - only a filepath. So we create script files
# corresponding to it here.

function format_envoy_command() {
    # First argument is concurrency count for Envoy
    concurrency=${1}
    config_type=${2}
    echo "/root/baseline_envoy --concurrency ${concurrency} -c /root/envoy-${config_type}.yaml 2>&1 >/dev/null" > /root/run_envoy_baseline.sh
    chmod +x /root/run_envoy_baseline.sh
}

function format_node_command() {
    rate=${1}
    concurrency=${2}
    duration=${3}
    config_type=${4}
    header_profile=${5}

    echo "forever start /root/tcp_server.js /root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/request_duration.csv" > /root/run_node.sh
    chmod +x /root/run_node.sh
}

function format_test_result_collection() {
    rate=${1}
    concurrency=${2}
    duration=${3}
    config_type=${4}
    header_profile=${5}
    
    # ping envoy in this case
    if [ "${4}" != "none" ]; then
        cat << EOF > /root/collect_results.sh
perf record -o /root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/perf.data -p \$(pgrep -f "/root/baseline_envoy" | head -1) -g -- sleep ${duration} &
/usr/bin/bullseye "http://localhost:10000" ${header_profile} ${rate} ${duration} 1>/root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/vegeta_success.plot 2>/root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/vegeta_errors.plot
curl http://localhost:7000/stats > /root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/envoy_metrics.log
pkill -INT -f "perf record"
EOF
    # otherwise don't ping Envoy, but the echo server directly
    else
        cat << EOF > /root/collect_results.sh
bullseye "http://localhost:8001" ${header_profile} ${rate} ${duration} > /root/results/${header_profile}/${rate}/${concurrency}/${duration}/${config_type}/vegeta.bin
EOF
    fi
    
    chmod +x /root/collect_results.sh
}

function run_test() {

   # move all running threads to different CPUs
   cset proc --move --kthread --fromset=root --toset=system --force

   for concurrency in ${concurrencies[*]}; do
       for rate in ${rates[*]}; do
           for duration in ${durations[*]}; do
	       for header_profile in ${header_profiles[*]}; do

                   # start node as baseline
		   format_node_command "${rate}" "${concurrency}" "${duration}" "none" "${header_profile}"

		   while ! pgrep --full node ; do
		   	   screen -dm bash -c 'cset proc --set=node --exec bash -- -c /root/run_node.sh' 
			   sleep 2
		   done

	           # get numbers without Envoy
                   format_test_result_collection "${rate}" "${concurrency}" "${duration}" "none" "${header_profile}"
                   cset proc --set=client --exec bash -- -c /root/collect_results.sh
		   
		   # kill node
		   forever stopall
		   # if some forever process is running, kill it. `forever list` prints 'No forever processes running'
		   # if no forever processes are running - the absence of that should trigger a kill. 
		   forever list | grep 'No forever' || kill $(forever list | awk '{print $8}' | tail -n +2)

	           # get numbers with Envoy - we run in a screen because cset doesn't handle & correctly
                   for config_type in ${envoy_config_types[*]}; do

                       # start node
		       format_node_command "${rate}" "${concurrency}" "${duration}" "${config_type}" "${header_profile}"
		       while ! pgrep --full tcp_server.js ; do
		       	       screen -dm bash -c 'cset proc --set=node --exec bash -- -c /root/run_node.sh' 
			       sleep 2
		       done
                       
		       format_envoy_command "${concurrency}" "${config_type}"
		       while ! pgrep --full /root/baseline_envoy ; do
	                       screen -dm bash -c "cset proc --set=envoy --exec bash -- -c /root/run_envoy_baseline.sh"
			       sleep 3
		       done
	               
		       if pgrep --full /root/baseline_envoy && pgrep --full tcp_server.js; then
		       		format_test_result_collection "${rate}" "${concurrency}" "${duration}" "${config_type}" "${header_profile}"
	               		cset proc --set=client --exec bash -- -c /root/collect_results.sh && kill -9 "$(pgrep -f '/root/baseline_envoy')"

	       	       fi
		       forever stopall
		       # if some forever process is running, kill it. `forever list` prints 'No forever processes running'
		       # if no forever processes are running - the absence of that should trigger a kill. 
		       forever list | grep 'No forever' || kill $(forever list | awk '{print $8}' | tail -n +2)
		   done
	       done
	   done
       done
   done
}

function analyze_data() {

    curl -L https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl > /root/stackcollapse-perf.pl
    curl -L https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl > /root/flamegraph.pl

    chmod +x /root/stackcollapse-perf.pl
    chmod +x /root/flamegraph.pl
    
    for name in $(find /root/results -name perf.data); do
    
    	cd $(dirname ${name})
    	
    	if [ ! -f perf.svg ]; then
    		echo "Building flamegraphs"
    		perf script | /root/stackcollapse-perf.pl | /root/flamegraph.pl > perf.svg
    	fi
    	
	cd /root

    done

}

function compress_results {
    # compress all the results into something smaller for easier uploading
    filename=${1}
    tar -zvcf ${filename} /root/results

}

run_test
analyze_data

date_of_completion=$(date | sed "s/ /-/g")
filename="/root/${date_of_completion}.tar.gz"
compress_results "${filename}"

chmod +x /root/upload.sh
/root/upload.sh "${filename}"

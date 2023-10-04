#! /usr/bin/env bash
# Copyright 2023 Francis Laniel <flaniel@linux.microsoft.com>
# SPDX-License-Identifier: Apache-2.0

SIZE_FORMAT='Standard_D%ds_v5'

function craft_node_size {
	local cores_nr

	if [ $# -ne 1 ]; then
		echo "${FUNCNAME[0]} needs 1 argument: cores_nr" 1>&2

		exit 1
	fi

	cores_nr=$1

	printf $SIZE_FORMAT $cores_nr
}

function get_kubectl {
	curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
	curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
	echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

	if [ $? -ne 0 ]; then
		echo "Bad kubectl checksum!" 1>&2

		exit 1
	fi

	chmod +x kubectl
	mkdir -p ~/.local/bin
	mv ./kubectl ~/.local/bin/kubectl

	export PATH="${PATH}:~/.local/bin"
}

# Taken from:
# https://krew.sigs.k8s.io/docs/user-guide/setup/install/
function get_krew {
	os="$(uname | tr '[:upper:]' '[:lower:]')"
	arch="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
	krew="krew-${os}_${arch}"

	curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${krew}.tar.gz"
	tar zxvf "${krew}.tar.gz"
	./"${krew}" install krew

	export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
}

function get_kubectl_gadget {
	kubectl krew install gadget
}

function get_all_nodes {
	kubectl get nodes --no-headers -o custom-columns=':metadata.name'
}

function prepare {
	local resource_group
	local kubernetes_cluster
	local nodes_nr
	local node_size

	if [ $# -ne 4 ]; then
		echo "${FUNCNAME[0]} needs 4 arguments: resource_group, kubernetes_cluster, nodes_nr, node_size" 1>&2

		exit 1
	fi

	get_kubectl
	get_krew
	get_kubectl_gadget

	resource_group=$1
	kubernetes_cluster=$2
	nodes_nr=$3
	node_size=$4

	az aks create --resource-group $resource_group --name $kubernetes_cluster -s $node_size -c $nodes_nr --generate-ssh-keys
	az aks get-credentials --resource-group $resource_group --name $kubernetes_cluster --overwrite-existing
}

function do_prepare_csv_file {
	local csv_file
	local nodes_nr

	if [ $# -ne 2 ]; then
		echo "${FUNCNAME[0]} needs 2 arguments: csv_file, nodes_nr" 1>&2

		exit 1
	fi

	csv_file=$1
	nodes_nr=$2

	echo -n "" > $csv_file

	# Create CSV header
	for i in $(seq 1 ${nodes_nr}); do
		echo -n "node-${i}," >> $csv_file
	done
}

function prepare_csv_file_gadget {
	local csv_file
	local nodes_nr

	if [ $# -ne 2 ]; then
		echo "${FUNCNAME[0]} needs 2 arguments: csv_file, nodes_nr" 1>&2

		exit 1
	fi

	csv_file=$1
	nodes_nr=$2

	do_prepare_csv_file $csv_file $nodes_nr

	echo "gadget" >> $csv_file
}

function prepare_csv_file_stats {
	local csv_file
	local nodes_nr

	if [ $# -ne 2 ]; then
		echo "${FUNCNAME[0]} needs 2 arguments: csv_file, nodes_nr" 1>&2

		exit 1
	fi

	csv_file=$1
	nodes_nr=$2

	do_prepare_csv_file $csv_file $nodes_nr

	echo "" >> $csv_file
}

function vertical_scaling {
	local resource_group
	local kubernetes_cluster
	local cores_nr

	if [ $# -ne 3 ]; then
		echo "${FUNCNAME[0]} needs 3 arguments: resource_group, kubernetes_cluster, cores_nr" 1>&2

		exit 1
	fi

	resource_group=$1
	kubernetes_cluster=$2
	cores_nr=$3

	size=$(craft_node_size $cores_nr)

	old_nodepool=$(az aks nodepool list --resource-group $resource_group --cluster-name $kubernetes_cluster --query '[0]' -o yaml)
	# Use grep, cut and tr to avoid needing jq.
	old_nodepool_name=$(echo $old_nodepool | grep 'name:' | cut -d':' -f2 | tr -d ' ')
	old_nodepool_nodes_nr=$(echo $old_nodepool | grep 'count:' | cut -d':' -f2 | tr -d ' ')

	# Recipe taken from:
	# https://learn.microsoft.com/en-us/azure/aks/resize-node-pool
	# nodepool name can contain only alphanumeric ([A-Za-z0-9]) characters and
	# length must not exceed 11 characters.
	az aks nodepool add --resource-group $resource_group --cluster-name $kubernetes_cluster --name "ncores${cores_nr}" --node-count $old_nodepool_nodes_nr --node-vm-size $size --mode System

	nodes=$(get_all_nodes)
	kubectl cordon $nodes
	kubectl drain $nodes --delete-emptydir-data --ignore-daemonsets

	az aks nodepool delete --resource-group $resource_group --cluster-name $kubernetes_cluster --name $old_nodepool_name
}

function horizontal_scaling {
	local resource_group
	local kubernetes_cluster
	local nodes_nr

	if [ $# -ne 3 ]; then
		echo "${FUNCNAME[0]} needs 3 arguments: resource_group, kubernetes_cluster, nodes_nr" 1>&2

		exit 1
	fi

	resource_group=$1
	kubernetes_cluster=$2
	nodes_nr=$3

	az aks scale --resource-group $resource_group --name $kubernetes_cluster --node-count $nodes_nr --nodepool-name nodepool1
}

function prepare_cluster {
	local mode
	local resource_group
	local kubernetes_cluster
	local resources_nr

	if [ $# -ne 4 ]; then
		echo "${FUNCNAME[0]} needs 4 argument: mode, resource_group, kubernetes_cluster, resources_nr" 1>&2

		exit 1
	fi

	mode=$1
	resource_group=$2
	kubernetes_cluster=$3
	resources_nr=$4

	# Depending on the mode, resources_nr has different meaning:
	# * vertical: number of CPU cores.
	# * horizontal: number of nodes.
	case $mode in
	'vertical')
		vertical_scaling $resource_group $kubernetes_cluster $resources_nr
		;;
	'horizontal')
		horizontal_scaling $resource_group $kubernetes_cluster $resources_nr
		;;
	*)
		echo "mode should be vertical or horizontal, got: ${mode}" 1>&2

		exit 1
		;;
	esac
}

function pre_run {
	local namespace

	if [ $# -ne 1 ]; then
		echo "${FUNCNAME[0]} needs 1 argument: namespace" 1>&2

		exit 1
	fi

	namespace=$1

	kubectl create ns $namespace
	kubectl gadget deploy
}

function run {
	local resources_nr
	local iter
	local namespace
	local gadget_dir
	local csv_file
	local cpu_csv_file
	local cpu_csv_file_before
	local memory_csv_file

	if [ $# -ne 8 ]; then
		echo "${FUNCNAME[0]} needs 8 arguments: resources_nr, iter, namespace, gadget_dir, csv_file, cpu_csv_file, cpu_csv_file_before, memory_csv_file" 1>&2

		exit 1
	fi

	resources_nr=$1
	iter=$2
	namespace=$3
	gadget_dir=$4
	csv_file=$5
	cpu_csv_file=$6
	cpu_csv_file_before=$7
	memory_csv_file=$8

	gadget_file="${gadget_dir}/gadget-output-${resources_nr}-${iter}.out"

	nodes=$(get_all_nodes)
	for node in $nodes; do
		# We get the node first, then the pod from the node.
		# This way, we ensure we have the same data order, i.e. node X corresponds
		# all the time to the same node.
		# TODO Use another language and a hash map.
		pod=$(kubectl get pod -n gadget --no-headers -o custom-columns=':metadata.name' --field-selector "spec.nodeName=${node}")
		container_id=$(kubectl describe pod -n gadget $pod | grep 'Container ID' | cut -d'/' -f3)
		cgroup_path=$(kubectl exec -n gadget $pod -- find /host/sys -name "*${container_id}*")

		cpu_usage=$(kubectl exec -n gadget $pod -- grep 'usage_usec' ${cgroup_path}/cpu.stat | awk '{ print $2 }')
		echo -n "${cpu_usage}," >> $cpu_csv_file_before
	done

	echo "" >> $cpu_csv_file_before

	kubectl gadget trace exec -n $namespace -o json > $gadget_file &
	gadget_pid=$!

	kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: daemonset-${resources_nr}
  namespace: $namespace
spec:
  selector:
    matchLabels:
      k8s-app: stress-exec
  template:
    metadata:
      labels:
        k8s-app: stress-exec
    spec:
      securityContext:
        runAsUser: 1000
        runAsNonRoot: true
      initContainers:
      - name: stress-exec
        image: ghcr.io/colinianking/stress-ng:master
        workingDir: /tmp
        command: ["/bin/sh"]
        args: ["-c", "stress-ng --exec $(nproc) --exec-fork-method clone --exec-method execve --exec-no-pthread --timeout 1s --metrics-brief"]
      containers:
      - name: do-nothing
        image: alpine:latest
        command: ["sleep", "inf"]
EOF
	kubectl wait --for condition=Ready pods --all -n $namespace --timeout 120s

	# With the above wait, we will be sure all the pods will be ready.
	# But we actually do the real stress test in init container.
	# So, we can stop Inspektor Gadget once all the "real" pods are ready.
	kill $gadget_pid

	for node in $nodes; do
		pod=$(kubectl get pod -n $namespace --no-headers -o custom-columns=':metadata.name' --field-selector "spec.nodeName=${node}")

		# stress-ng output is like this:
		# stress-ng: info:  [1] setting to a 1 second run per stressor
		# stress-ng: info:  [1] dispatching hogs: 8 exec
		# stress-ng: info:  [1] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s
		# stress-ng: info:  [1]                           (secs)    (secs)    (secs)   (real time) (usr+sys time)
		# stress-ng: info:  [1] exec               9157      1.00      4.44      1.51      9151.35        1538.99
		# stress-ng: info:  [1] successful run completed in 1.00s
		# We want to bogo ops, so they are in the 5th column and the only element to
		# be a number in this column.
		# We also need to specify the container with -c to get the logs of the init
		# container "stress-exec".
		nr_exec=$(kubectl logs -n $namespace $pod -c stress-exec | awk '{ print $5 }' | grep -P '\d+')
		echo -n "${nr_exec}," >> $csv_file
	done

	wc -l $gadget_file | awk '{ print $1 }' >> $csv_file

	for node in $nodes; do
		pod=$(kubectl get pod -n gadget --no-headers -o custom-columns=':metadata.name' --field-selector "spec.nodeName=${node}")
		container_id=$(kubectl describe pod -n gadget $pod | grep 'Container ID' | cut -d'/' -f3)
		cgroup_path=$(kubectl exec -n gadget $pod -- find /host/sys -name "*${container_id}*")

		cpu_usage=$(kubectl exec -n gadget $pod -- grep 'usage_usec' ${cgroup_path}/cpu.stat | awk '{ print $2 }')
		echo -n "${cpu_usage}," >> $cpu_csv_file

		memory_current=$(kubectl exec -n gadget $pod -- cat ${cgroup_path}/memory.current)
		echo -n "${memory_current}," >> $memory_csv_file
	done

	echo "" >> $cpu_csv_file
	echo "" >> $memory_csv_file
}

function post_run {
	local namespace

	if [ $# -ne 1 ]; then
		echo "${FUNCNAME[0]} needs 1 argument: namespace" 1>&2

		exit 1
	fi

	namespace=$1

	kubectl delete ns $namespace
	kubectl gadget undeploy
}

function run_exp {
	local script_name
	local resource_group
	local kubernetes_cluster
	local resources_nr
	local resource_suffix
	local nodes_nr
	local output_dir

	local namespace
	local gadget_dir
	local csv_file
	local cpu_csv_file_before
	local cpu_csv_file
	local memory_csv_file

	if [ $# -ne 7 ]; then
		echo "${FUNCNAME[0]} needs 7 arguments: script_name, resource_group, kubernetes_cluster, resources_nr, resource_suffix nodes_nr output_dir" 1>&2

		exit 1
	fi

	script_name=$1
	resource_group=$2
	kubernetes_cluster=$3
	resources_nr=$4
	resource_suffix=$5
	nodes_nr=$6
	output_dir=$7

	namespace="test-scaling-${resources_nr}-${resource_suffix}"
	gadget_dir="${output_dir}/gadget-output-${resources_nr}-${resource_suffix}"
	csv_file="${output_dir}/exec-${resources_nr}-${resource_suffix}.csv"
	cpu_csv_file_before="${output_dir}/cpu-before-${resources_nr}-${resource_suffix}.csv"
	cpu_csv_file="${output_dir}/cpu-${resources_nr}-${resource_suffix}.csv"
	memory_csv_file="${output_dir}/memory-${resources_nr}-${resource_suffix}.csv"

	prepare_cluster $script_name $resource_group $kubernetes_cluster $resources_nr

	mkdir $output_dir
	mkdir $gadget_dir

	prepare_csv_file_gadget $csv_file $nodes_nr
	prepare_csv_file_stats $cpu_csv_file $nodes_nr
	prepare_csv_file_stats $cpu_csv_file_before $nodes_nr
	prepare_csv_file_stats $memory_csv_file $nodes_nr

	# Run the experiment.
	for exp in {1..30}; do
		pre_run $namespace
		run $resources_nr $exp $namespace $gadget_dir $csv_file $cpu_csv_file $cpu_csv_file_before $memory_csv_file
		post_run $namespace
	done
}

function unprepare {
	local resource_group
	local kubernetes_cluster

	if [ $# -ne 2 ]; then
		echo "${FUNCNAME[0]} needs 2 arguments: resource_group, kubernetes_cluster" 1>&2

		exit 1
	fi

	resource_group=$1
	kubernetes_cluster=$2

	az aks delete --resource-group $resource_group --name $kubernetes_cluster --no-wait --yes
}

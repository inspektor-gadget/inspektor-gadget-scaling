#! /usr/bin/env bash
# Copyright 2023 Francis Laniel <flaniel@linux.microsoft.com>
# SPDX-License-Identifier: Apache-2.0

script_name=$(basename $0 '.sh')

resource_group='ig-test-hscalingrg'
kubernetes_cluster='ig-test-hscalingcluster'
cores_nr=16
nodes='2,12,25,37,50'
output_dir="${script_name}-$(date +%d-%m-%y-%H-%M-%S)"

while getopts "g:c:n:o:h" option; do
	case $option in
	g)
		resource_group=${OPTARG}
		;;
	k)
		kubernetes_cluster=${OPTARG}
		;;
	c)
		cores_nr=${OPTARG}
		;;
	n)
		nodes=${OPTARG}
		;;
	o)
		output_dir=${OPTARG}
		;;
	h|\?)
		echo "Usage: $0 [-g resource_group] [-c kubernetes_cluster] [-n cores_nr]" 1>&2
		echo -e "\t-g: The given string will be used as resource group name, ${resource_group} by default." 1>&2
		echo -e "\t-k: The given string will be used as cluster name, ${kubernetes_cluster} by default." 1>&2
		echo -e "\t-c: The given number will be used as node size, 16 cores by default." 1>&2
		echo -e "\t-n: The given comma-separated string will be used as number of nodes to run the experiment, 2, 12, 25, 37 and 50 by default." 1>&2
		echo -e "\t-o: The output directory to store all results files, ${output_dir} by default." 1>&2
		echo -e "\t-h: Print this help message." 1>&2
		exit 1
		;;
	esac
done

source sources.sh

node_size=$(craft_node_size $cores_nr)
prepare $resource_group $kubernetes_cluster 1 $node_size

for nodes_nr in $(echo $nodes | tr ',' '\n'); do
	run_exp $script_name $resource_group $kubernetes_cluster $nodes_nr 'nodes' $nodes_nr $output_dir
done

unprepare $resource_group $kubernetes_cluster

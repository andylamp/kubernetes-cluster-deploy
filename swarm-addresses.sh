#!/usr/bin/env bash

# this is our master node
MASTER_NODE="master.example.cluster.com"

# this is the array which contains all the SLAVE nodes
declare -a SLAVE_NODES=(
    "worker1.example.cluster.com"
    "worker2.example.cluster.com"
    "workerN.example.cluster.com"
)
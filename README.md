# Easily Deploy a Kubernetes Cluster

This script is designed to easily provision a bare-metal [kubernetes][1] cluster given the addresses of the slaves 
and master nodes in the pool - it was developed to be used for Debian-based distributions, however it can be 
(easily) modified to be used in others as well.

# Requirements

Generally speaking a vanilla cluster with Debian based distribution is enough, however they need to support the 
following:

 - Kubernetes
 - Docker
 - ssh access to each machine (with `sudo`)
 
# How it works

The script is comprised out of two main components the "bootstrapper" script which is the one you have to run and 
the one that actually performs the installation on the machines; these are the following:

 - [kubernetes-swarm-deploy.sh][5]: the bootstrapper script
 - [kubernetes-swarm-remote-installer.sh][6]: the actual installer that runs in each node
 - [swarm-addresses.sh][7]: the addresses of the nodes
 
The way it works is that the deploy script is executed from a machine of choice and based on the provided addresses 
in the [swarm-addresses.sh][7] it performs the appropriate actions for `slave` and `master` nodes respectively.

The contents of the `swarm-addresses.sh` should be like this:

```bash
# this is our master node
MASTER_NODE="master.example.cluster.com"

# this is the array which contains all the SLAVE nodes
declare -a SLAVE_NODES=(
    "worker1.example.cluster.com"
    "worker2.example.cluster.com"
    "workerN.example.cluster.com"
)
```

Where the `MASTER_NODE` indicates the address of the master node and the `SLAVE_NODES` array contains 
the addresses for each one of the slave nodes. 

The first thing that happens is to create and configure the master node in the swarm, which is necessary since only that
particular node can generate the required join command - this is done as follows

```bash
# install the mater node
if [[ ${SETUP_MASTER} = true ]]; then
    cli_info "Setting up master node at ${MASTER_NODE}."
    ssh -t "${USER}@${MASTER_NODE}" \
    TARGET_NODE="$(printf '%q' "${MASTER_NODE}")" "$(<./kubernetes-swarm-remote-installer.sh)"
fi
```

The `ssh` is particularly tricky, as not only we need to have an interactive shell in the remote machine but we 
also require `sudo` access. I will try to elaborate a bit on that by using the `slave` command instead, which is the 
following:

```bash
ssh -t "${USER}@${slave}" \
TARGET_NODE="$(printf '%q' "${slave}")" \
JOIN_CMD="$(printf '%q' "${JOIN_CMD}")" "$(<./kubernetes-swarm-remote-installer.sh)"
```


Now, let's decompose the above command so it is a bit more user friendly as there are quite a few intricacies involved.
First, let's review what we want to do; we need to execute an interactive shell in each remote machine, 
with `sudo` access executing `kubernetes-swarm-remote-installer.sh`. The immediate thing to do is to do something 
like this:

```bash
ssh -t ${USER}@${slave} "$(<./kubernetes-swarm-remote-installer.sh)" TARGET_NODE="$(printf '%q' "${slave}")"
```

However, script arguments are **not** accepted after the script, as such the above command will fail. 
The solution to that issue is to pass them as *evaluated* environment variables which are passed, *after evaluation* 
to the ssh session; i.e.

```bash
ssh -t ${USER}@${slave} TARGET_NODE="$(printf '%q' "${slave}")" "$(<./kubernetes-swarm-remote-installer.sh)"
```

Do note that ordering is quite important here, however there is still a problem as the remote script *cannot* be 
interactive when having to `sudo` commands in the remote script by using normal means - i.e.:

```bash
ssh -t ${USER}@${slave} 'bash -s' < ./my-script.sh
```

To achieve that, it has to be done by completely evaluating the script to be executed on the remote host - i.e.:

```bash
ssh -t ${USER}@${slave} "$(<./kubernetes-swarm-remote-installer.sh)"
```

Now the `master` and `slave` node installation commands should make more sense; The `slave` node array is looped 
for each of the entries in the `SLAVE_NODES` array.

# Configuring separate namespaces

Sometimes in each cluster we need to have two or more groups coexist in parallel but in isolation - i.e.: they do 
not see each others contents yet share the same resources. Thankfully, an article explaining how to do that could be 
found [here][4] which I used to create [this][8] script. You can use that to create the different namespaces for each 
of the groups or teams you want to isolate as following:

```bash
# if not already executable, make it
chmod +x ./create-namespace-user.sh
# now execute it
./create-namespace-user.sh "namespace-name"
```

Note that you need to be the administrator of the cluster in order to run this script and it *has* to be executed from 
the master node directly or use the method described above to do so remotely.

# Creating Persistent Volume Claims

Another issue that can be quite painful at times, is how to create persistent disk storage for individual namespaces.
However, in recent kubernetes versions it is relatively easy to do so, do this end I have provided a `yaml` that 
allows that [here][9] which. Please note that in order for this to be executed successfully you also need to have a 
nfs service running in your cluster, a template to create such a service can be found [here][10]. 

[1]: https://kubernetes.io/
[2]: https://kubernetes.io/docs/reference/kubectl/cheatsheet/
[3]: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
[4]: https://jeremievallee.com/2018/05/28/kubernetes-rbac-namespace-user.html
[5]: kubernetes-swarm-deploy.sh
[6]: kubernetes-swarm-remote-installer.sh
[7]: swarm-addresses.sh
[8]: create-namespace-user.sh
[9]: claims/pvc-claim-template.yaml
[10]: claims/nfs-provisioner.yaml
# Part 2: Kubernetes from Scratch

In Part 1 you saw that a container is a process with namespaces and cgroups, and you built a "pod" by hand.

In this part you will build a real Kubernetes cluster and use it to run our music API, step by step:

1. Create a cluster and look at its parts
2. Run a pod, then look inside it
3. Keep pods alive with a ReplicaSet and a Deployment
4. Give pods a stable address with a Service
5. Separate config from code with ConfigMaps and Secrets
6. Health checks, rolling updates and rollbacks
7. Limits, scheduling, a node failing, and autoscaling
8. A one-off Job, and a look under the hood

Type every command exactly as shown, inside the lab shell (`lab:/lab#`).
If you have not started the lab yet, do **Step 0** of Part 1 first.

---

# Section 1: The cluster

## Step 1: Create a Kubernetes cluster

```
cd /lab
cat kind-cluster.yaml
```

**What you see:** one **control-plane** node and two **worker** nodes.

Create the cluster (this takes 1 to 2 minutes):

```
kind create cluster --config kind-cluster.yaml
```

Wait until all nodes are ready:

```
kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

```
kubectl get nodes -o wide
```

**What you see:** `lab-control-plane`, `lab-worker` and `lab-worker2`, all `Ready`.

**Why:** **kind** means "Kubernetes in Docker". Each node is a Docker container that pretends to be a machine. In a real company, each node is a real or virtual machine.

See the nodes as containers:

```
docker ps --format 'table {{.Names}}\t{{.Image}}'
```

## Step 2: Look at the control plane

```
kubectl get pods -n kube-system -o wide
```

**What you see:**

| Pod name starts with | What it is | Runs on |
|---|---|---|
| `etcd` | The database. Stores every object in the cluster | control-plane |
| `kube-apiserver` | The front door. Everything talks to it | control-plane |
| `kube-scheduler` | Picks a node for each new pod | control-plane |
| `kube-controller-manager` | Runs the loops that make reality match what you asked for | control-plane |
| `kube-proxy` | Writes network rules for Services | every node |
| `kindnet` | Gives pods IP addresses and connects nodes | every node |
| `coredns` | DNS for names inside the cluster | any node (here, the control-plane) |

**Why:** the control plane **decides**. The worker nodes **run** your containers. On each node, a program called the **kubelet** starts the containers.

## Step 3: How kubectl talks to the cluster

```
kubectl config view --minify
```

**What you see:** a `server:` line like `https://127.0.0.1:...`. That is the API server's address.

```
kubectl get nodes -v=6 2>&1 | grep GET
```

**What you see:** a line with `verb="GET"` and `url="https://127.0.0.1:.../api/v1/nodes..."`. That is the HTTPS request kubectl sent.

**Why:** `kubectl` is just a program that sends HTTPS requests to the API server. It never talks to nodes or pods directly.

## Step 4: Build our app images and copy them into the cluster

Build three versions of the app. `v3-broken` is broken on purpose (used in Step 21):

```
cd /lab/spotify-api
docker build -t spotify-api:v1 .
docker build -t spotify-api:v2 --build-arg APP_VERSION=v2 .
docker build -t spotify-api:v3-broken --build-arg APP_VERSION=v3 --build-arg BROKEN=true .
```

The nodes cannot see the lab's images. Copy the images into every node (this takes about a minute):

```
kind load docker-image spotify-api:v1 spotify-api:v2 spotify-api:v3-broken busybox:1.36 python:3.12-slim registry.k8s.io/metrics-server/metrics-server:v0.9.0 --name lab
```

Check that a worker node now has them:

```
docker exec lab-worker crictl images | grep -E "spotify|busybox"
```

**Why:** a node can only run a container if the image is on that node. Normally nodes download images from a registry (like Docker Hub). Here we copy them in, so the lab works without internet.

All Kubernetes files are in `/lab/k8s`:

```
cd /lab/k8s
ls
```

---

# Section 2: Pods

## Step 5: Run your first pod

```
cat 01-pod.yaml
```

**What you see:** every Kubernetes file has the same four parts:

- `apiVersion` and `kind`: what type of object this is
- `metadata`: its name and labels
- `spec`: what you **want**

Create it:

```
kubectl apply -f 01-pod.yaml
kubectl wait --for=condition=Ready pod/spotify-pod --timeout=60s
kubectl get pods -o wide
```

**What you see:** `spotify-pod` is `Running`, with its own **IP address** and the **node** it runs on.

See the full story of the pod:

```
kubectl describe pod spotify-pod
```

**What you see:** at the bottom, **Events**: `Scheduled` (the scheduler picked a node), `Pulled`, `Created`, `Started` (the kubelet started the container).

See its logs and run a command inside it:

```
kubectl logs spotify-pod
kubectl exec spotify-pod -- hostname
kubectl exec spotify-pod -- ls /app
```

## Step 6: Call the pod from the lab shell

Open a tunnel from port 8081 of the lab to port 5000 of the pod:

```
kubectl port-forward pod/spotify-pod 8081:5000 --address 0.0.0.0 > /dev/null &
sleep 2
```

```
curl -s localhost:8081/songs/most-listened | jq
curl -s localhost:8081/artists/top | jq
curl -s localhost:8081/artists/3/songs | jq
```

**What you see:** the music API answering. Notice `served_by: spotify-pod`.

On your laptop browser: **http://localhost:8081/songs/most-listened**

Stop the tunnel:

```
pkill -f "port-forward"
```

## Step 7: A pod alone does not come back

```
kubectl delete pod spotify-pod
kubectl get pods
```

**What you see:** `No resources found`.

**Why:** a pod on its own is never recreated. If it is deleted, or its node dies, it is gone. Step 9 fixes this.

## Step 8: Look inside a pod with two containers

```
cat 02-pod-two-containers.yaml
```

**What you see:** one pod with two containers, `api` and `helper`, and a shared folder called `shared`.

```
kubectl apply -f 02-pod-two-containers.yaml
kubectl wait --for=condition=Ready pod/two-in-one --timeout=60s
kubectl get pod two-in-one -o wide
```

**What you see:** `READY 2/2`. One pod, one IP address, on node `lab-worker`.

The helper reaches the app on **localhost**:

```
kubectl exec two-in-one -c helper -- wget -qO- localhost:5000/artists/top
```

The helper has the **pod's** IP address:

```
kubectl exec two-in-one -c helper -- ip addr show eth0
```

But it has its **own** processes and files:

```
kubectl exec two-in-one -c helper -- ps -ef
kubectl exec two-in-one -c helper -- ls /app
```

The shared folder is visible to both:

```
kubectl exec two-in-one -c helper -- sh -c 'echo "hello from helper" > /shared/note.txt'
kubectl exec two-in-one -c api -- cat /shared/note.txt
```

Now look at the node itself. Every pod has a tiny **pause** container that holds its network:

```
docker exec lab-worker crictl pods
docker exec lab-worker crictl ps
docker exec lab-worker pgrep -a pause
```

**What you see:** `crictl pods` lists the pods on this node, `crictl ps` lists their containers (`api` and `helper` belong to pod `two-in-one`), and there is one `/pause` process for every pod.

**Why:** this is exactly the "pod by hand" from Part 1, Step 21. A pod is a group of containers that share **one network namespace** (one IP, `localhost`) and can share folders. Each container keeps its own files and processes.

Clean up. `--now` stops it right away. Without it, Kubernetes waits up to 30 seconds, because `sleep` running as PID 1 ignores the polite stop signal (SIGTERM):

```
kubectl delete pod two-in-one --now
```

---

# Section 3: Keeping pods alive

## Step 9: Labels and a ReplicaSet

Every object can have **labels**: `key: value` tags. Look at the labels on the nodes:

```
kubectl get nodes --show-labels
```

```
cat 03-replicaset.yaml
```

**What you see:**

- `replicas: 3`: keep 3 pods running
- `selector`: "the pods with label `app: spotify-rs` are mine"
- `template`: how to create a new pod when one is missing

```
kubectl apply -f 03-replicaset.yaml
kubectl get rs
kubectl get pods --show-labels
```

**What you see:** 3 pods with random names, all with the label `app=spotify-rs`.

Delete all of them:

```
kubectl delete pods -l app=spotify-rs
kubectl get pods
```

**What you see:** 3 **new** pods with **new** names.

**Why:** the ReplicaSet runs a loop: count the pods with my label, compare with 3, create or delete pods until they match.

## Step 10: A ReplicaSet counts by label, not by name

Change the label on all its pods:

```
kubectl label pods -l app=spotify-rs app=quarantine --overwrite
kubectl get pods --show-labels
```

**What you see:** **6** pods. 3 with `app=quarantine` and 3 new ones with `app=spotify-rs`.

**Why:** the ReplicaSet counted 0 pods with its label, so it created 3 more. The old ones are still running, but no longer belong to it. Teams use this trick to take a broken pod out of service and debug it.

Remove the quarantined pods:

```
kubectl delete pods -l app=quarantine
```

## Step 11: A ReplicaSet cannot update versions

Change the image of the ReplicaSet to `v2`:

```
kubectl set image rs/spotify-rs api=spotify-api:v2
kubectl get pods -l app=spotify-rs -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

**What you see:** all pods still run `spotify-api:v1`.

**Why:** the pods match the label and there are 3 of them, so the ReplicaSet has nothing to fix. A ReplicaSet only keeps the **count** right. It does not know how to move from one version to another.

Delete the ReplicaSet. `--cascade=foreground` waits until its pods are deleted too:

```
kubectl delete rs spotify-rs --cascade=foreground
```

## Step 12: A Deployment manages versions

```
cat 04-deployment.yaml
```

It looks like the ReplicaSet, plus a `strategy` that says how to change versions.

```
kubectl apply -f 04-deployment.yaml
kubectl rollout status deployment spotify-api
kubectl get deploy,rs,pods -o wide
```

**What you see:** a chain of names:

```
deployment   spotify-api
replicaset   spotify-api-<hash>
pod          spotify-api-<hash>-<random>
```

The pods are spread across `lab-worker` and `lab-worker2`.

Each pod says who owns it:

```
kubectl describe pods -l app=spotify-api | grep "Controlled By"
```

Scale up and down:

```
kubectl scale deployment spotify-api --replicas=5
kubectl get pods -o wide
kubectl scale deployment spotify-api --replicas=3
```

**Why:**

- the **Deployment** manages **versions** (it creates one ReplicaSet per version)
- the **ReplicaSet** keeps the **count** right
- the **Pod** is one running copy on one node

You only ever write Deployments. You will update versions in Step 20.

---

# Section 4: Networking

## Step 13: A Service gives pods one stable address

Pods come and go, and each new pod gets a new IP address. A **Service** gives them one name and one IP address that never change.

```
cat 05-service.yaml
```

**What you see:** "send traffic on port **80** to pods with label `app: spotify-api` on port **5000**".

```
kubectl apply -f 05-service.yaml
kubectl get svc spotify-svc
```

**What you see:** a `CLUSTER-IP`. This is the Service's fixed address.

See which pods are behind it right now:

```
kubectl get endpointslices -l kubernetes.io/service-name=spotify-svc
kubectl get pods -o wide
```

**What you see:** the endpoint list has the same IP addresses as the pods.

Start a small client pod to make calls from inside the cluster:

```
kubectl run client --image=busybox:1.36 --restart=Never -- sleep 36000
kubectl wait --for=condition=Ready pod/client --timeout=60s
```

See where the client sends DNS questions:

```
kubectl exec client -- cat /etc/resolv.conf
```

**What you see:** a `nameserver` (that is CoreDNS) and `search default.svc.cluster.local ...`

Look up the Service name:

```
kubectl exec client -- nslookup spotify-svc.default.svc.cluster.local
```

**What you see:** the Service's **CLUSTER-IP**, not a pod IP.

Call the Service by its short name (`-T 5` means give up after 5 seconds):

```
kubectl exec client -- wget -T 5 -qO- spotify-svc/songs/most-listened
```

Call it 6 times and see which pod answered each time:

```
kubectl exec client -- sh -c 'for i in 1 2 3 4 5 6; do wget -T 5 -qO- spotify-svc/ | grep -o "\"served_by\":\"[^\"]*\""; done'
```

**What you see:** different pod names. The Service spreads calls across the pods.

## Step 14: The Service IP does not belong to any machine

Try to ping the Service IP:

```
kubectl exec client -- ping -c 2 -W 1 spotify-svc
```

**What you see:** no replies.

Look at the rules `kube-proxy` wrote on a node:

```
docker exec lab-worker iptables-save -t nat | grep "default/spotify-svc"
```

**What you see:** rules that say "traffic to the CLUSTER-IP on port 80: pick one pod at random (`probability`) and send it to that pod's IP on port 5000 (`DNAT`)".

**Why:** a Service is a **record**, not a program. Its IP only exists inside these rules, which are on **every** node. When a pod calls the Service, its own node's kernel replaces the Service IP with a real pod IP before sending the packet. Nothing answers `ping` on the Service IP.

## Step 15: Reach the app from outside the cluster (NodePort)

```
cat 06-nodeport.yaml
kubectl apply -f 06-nodeport.yaml
kubectl get svc spotify-nodeport
```

```
curl -s localhost:30080/artists/top | jq
```

On your laptop browser: **http://localhost:30080/songs/most-listened**

**Why:** a **NodePort** Service opens the same port (here 30080) on **every** node and forwards it to the pods. In real companies, a cloud load balancer or an Ingress gateway sits in front of this.

## Step 16: Namespaces in Kubernetes

Kubernetes namespaces are **folders for objects**. They are not the same as Linux namespaces from Part 1.

```
kubectl get namespaces
```

Create a new namespace with its own client pod. It is also named `client`:

```
kubectl create namespace team-b
kubectl run client -n team-b --image=busybox:1.36 --restart=Never -- sleep 36000
kubectl wait -n team-b --for=condition=Ready pod/client --timeout=60s
kubectl get pods -A | grep client
```

**What you see:** two pods named `client`, in two namespaces.

From `team-b`, the short name does not work:

```
kubectl exec -n team-b client -- wget -T 3 -qO- spotify-svc/
```

**What you see:** `bad address 'spotify-svc'`.

The name with the namespace works:

```
kubectl exec -n team-b client -- wget -T 5 -qO- spotify-svc.default/artists/top
```

**Why:** the short name only works inside the same namespace. From another namespace, add the namespace to the name.

Deleting a namespace deletes everything inside it (this takes about 30 seconds):

```
kubectl delete namespace team-b
```

---

# Section 5: Config, health and updates

## Step 17: ConfigMaps and Secrets

The same image must run everywhere, but settings differ per environment. So settings live **outside** the image.

```
cat 07-configmap-secret.yaml
kubectl apply -f 07-configmap-secret.yaml
```

```
kubectl get configmap spotify-config -o yaml
kubectl get secret spotify-secret -o yaml
```

**What you see:** the Secret's value looks scrambled. It is only **base64**, not encryption:

```
kubectl get secret spotify-secret -o jsonpath='{.data.API_KEY}' | base64 -d
echo
```

Now use them in the Deployment:

```
cat 08-deployment-with-config.yaml
```

**What you see:**

- `GREETING` and `REGION` come from the ConfigMap as **environment variables**
- `API_KEY` comes from the Secret as an environment variable
- the whole ConfigMap is also mounted as **files** in `/config`

```
kubectl apply -f 08-deployment-with-config.yaml
kubectl rollout status deployment spotify-api
sleep 10
kubectl exec client -- wget -T 5 -qO- spotify-svc/config | jq
```

`sleep 10` gives the old pods time to finish shutting down, so only new pods answer.

**What you see:** `env` shows the values from the ConfigMap and Secret. `files_in_config_folder` shows one file per ConfigMap key.

## Step 18: Changing a ConfigMap

```
cat 07-configmap-updated.yaml
kubectl apply -f 07-configmap-updated.yaml
```

Wait about a minute, then:

```
kubectl exec client -- wget -T 5 -qO- spotify-svc/config | jq
```

**What you see:**

- the **files** show the new text
- the **environment variable** `GREETING` still has the old text

**Why:** environment variables are given to a process only when it starts. Files are refreshed by the kubelet. To pick up the new environment, start new pods:

```
kubectl rollout restart deployment spotify-api
kubectl rollout status deployment spotify-api
sleep 10
kubectl exec client -- wget -T 5 -qO- spotify-svc/config | jq .env
```

**What you see:** `GREETING` now has the new text.

## Step 19: Health checks (probes) and resource requests

```
cat 09-deployment-with-probes.yaml
```

**What you see:**

- `readinessProbe`: calls `/readyz`. If it fails, the pod gets **no traffic**
- `livenessProbe`: calls `/healthz`. If it fails, the container is **restarted**
- `resources`: how much CPU and memory the pod asks for (`requests`) and its maximum (`limits`)

```
kubectl apply -f 09-deployment-with-probes.yaml
kubectl rollout status deployment spotify-api
sleep 10
kubectl get pods
```

**Liveness:** make one pod's health check fail:

```
kubectl exec deploy/spotify-api -- touch /tmp/not-alive
```

Wait 20 seconds, then:

```
kubectl get pods
```

**What you see:** one pod has `RESTARTS 1`, and it is healthy again.

**Why:** the kubelet saw `/healthz` fail and restarted the container. The new container started with a fresh filesystem, so the file `/tmp/not-alive` was gone. Anything written inside a container is lost on restart.

**Readiness:** make one pod "not ready":

```
kubectl exec deploy/spotify-api -- touch /tmp/not-ready
```

Wait 5 seconds, then:

```
kubectl get pods
```

**What you see:** one pod shows `READY 0/1`, but it is still `Running` with no restarts.

Call the Service 6 times:

```
kubectl exec client -- sh -c 'for i in 1 2 3 4 5 6; do wget -T 5 -qO- spotify-svc/ | grep -o "\"served_by\":\"[^\"]*\""; done'
```

**What you see:** only **2** different pod names. The not-ready pod gets no traffic.

**Why:** liveness answers "should I restart it?". Readiness answers "should it get traffic?". The next step replaces all pods, which fixes the not-ready one.

## Step 20: Rolling update to a new version

Tip: to watch the update live, open a second laptop terminal, run `docker exec -it k8s-lab bash`, then `kubectl get pods -w`.

```
kubectl set image deployment/spotify-api api=spotify-api:v2
kubectl rollout status deployment spotify-api
sleep 10
```

```
kubectl get rs
kubectl exec client -- wget -T 5 -qO- spotify-svc/ | jq .version
```

**What you see:**

- a **new** ReplicaSet with 3 pods, and the old one with 0 pods (kept for rollback)
- the API answers `"v2"`

**Why:** the Deployment created a new ReplicaSet for `v2`, then added one new pod, waited until it was ready, removed one old pod, and repeated. There was always a ready pod serving traffic.

The `preStop` setting in the file makes each old pod wait 5 seconds before it stops. During that time every node removes the old pod from its Service rules, so no request is sent to a pod that is shutting down.

```
kubectl rollout history deployment spotify-api
```

## Step 21: A broken version, and a rollback

`v3-broken` never passes its readiness check:

```
kubectl set image deployment/spotify-api api=spotify-api:v3-broken
kubectl rollout status deployment spotify-api --timeout=30s
```

**What you see:** the command gives up after 30 seconds.

```
kubectl get pods
kubectl exec client -- wget -T 5 -qO- spotify-svc/ | jq .version
```

**What you see:**

- one new pod stuck at `READY 0/1`
- the 3 old pods are still running, and the API still answers `"v2"`

**Why:** the new pod never became ready, so the rollout stopped. Users never saw the broken version.

Go back:

```
kubectl rollout undo deployment spotify-api
kubectl rollout status deployment spotify-api
kubectl get pods
```

**What you see:** the broken pod is `Terminating` (or already gone). All other pods run `v2`.

You may also see a warning that the Deployment "was previously managed with kubectl apply". It is harmless here. In real teams, the change would be made in Git and applied again instead.

---

# Section 6: Limits, scheduling, failures and scaling

## Step 22: Going over the memory limit (OOMKilled)

```
cat 10-memory-hog.yaml
kubectl apply -f 10-memory-hog.yaml
```

Wait 15 seconds, then:

```
kubectl get pod memory-hog
kubectl describe pod memory-hog | grep -A 3 "Last State"
```

**What you see:** `OOMKilled`, and then `CrashLoopBackOff`.

**Why:** the container tried to use more memory than its `limit`. The kernel's cgroup killed it (exactly like Part 1, Step 12). The kubelet keeps restarting it, waiting longer each time.

```
kubectl delete pod memory-hog
```

## Step 23: A pod that cannot be placed (Pending)

```
cat 10-too-big.yaml
kubectl apply -f 10-too-big.yaml
```

Wait 5 seconds, then:

```
kubectl get pod too-big
kubectl describe pod too-big | grep -A 5 Events
```

**What you see:** `Pending`, and `0/3 nodes are available: ... Insufficient cpu`.

**Why:** the scheduler only places a pod on a node that has enough free CPU and memory for its `requests`. No node has 50 CPUs.

See how much of a node is already promised to pods:

```
kubectl describe node lab-worker | grep -A 8 "Allocated resources"
kubectl delete pod too-big
```

## Step 24: A node dies

See where the pods are:

```
kubectl get pods -l app=spotify-api -o wide
```

Stop the `lab-worker2` node (this is like pulling its power cable):

```
docker stop lab-worker2
```

Wait about 1 minute, then:

```
kubectl get nodes
```

**What you see:** `lab-worker2` is `NotReady`.

Wait about 30 seconds more, then:

```
kubectl get pods -l app=spotify-api -o wide
```

**What you see:**

- the pods on `lab-worker2` show `Terminating`
- new pods are `Running` on `lab-worker`, so there are still 3 running copies

**Why:** the node stopped sending heartbeats. The control plane marked it `NotReady` and marked its pods for deletion. The ReplicaSet saw fewer than 3 running pods and created new ones on a healthy node. No human was involved.

The old pods stay `Terminating` because the dead node cannot confirm they stopped. They disappear when the node comes back.

Bring the node back:

```
docker start lab-worker2
kubectl wait --for=condition=Ready node/lab-worker2 --timeout=180s
kubectl get nodes
kubectl get pods -l app=spotify-api -o wide
```

**What you see:** `lab-worker2` is `Ready` again. Within a few seconds the `Terminating` pods disappear (run the last command again if you still see them). The running pods stay where they are. Kubernetes does not move pods back.

## Step 25: Autoscaling (HPA)

Install **metrics-server**, which measures CPU use of pods:

```
kubectl apply -f addons/metrics-server.yaml
kubectl -n kube-system rollout status deployment metrics-server --timeout=180s
```

Wait about 1 minute, then:

```
kubectl top nodes
kubectl top pods
```

Create the autoscaler: "keep average CPU at 50% of the request, between 3 and 6 pods":

```
cat 11-hpa.yaml
kubectl apply -f 11-hpa.yaml
```

Start a pod that calls a CPU-heavy endpoint again and again:

```
kubectl run load --image=busybox:1.36 --restart=Never -- sh -c 'while true; do wget -qO- spotify-svc/burn > /dev/null; done'
```

Wait about 2 minutes, then:

```
kubectl get hpa
kubectl get pods -l app=spotify-api
```

**What you see:** CPU use above 50%, and **more pods** (up to 6).

**Why:** every 15 seconds the HPA reads CPU use and changes the Deployment's `replicas`. The Deployment and ReplicaSet do the rest.

Stop the load:

```
kubectl delete pod load --now
```

The HPA waits 5 minutes before removing pods, so it does not go up and down too often.

---

# Section 7: Jobs and under the hood

## Step 26: A Job runs once and finishes

```
cat 12-job.yaml
kubectl apply -f 12-job.yaml
kubectl wait --for=condition=complete job/db-migration --timeout=120s
kubectl get jobs
kubectl get pods -l job-name=db-migration
kubectl logs job/db-migration
```

**What you see:** the Job is `Complete`, and its pod is `Completed`, not restarted.

**Why:** a Deployment keeps pods running forever. A **Job** runs a task until it succeeds, then stops. Teams use Jobs for things like database migrations before a release.

## Step 27: Everything is a record in etcd

The Deployment is just a record. Read it straight from the API server:

```
kubectl get --raw /apis/apps/v1/namespaces/default/deployments/spotify-api | jq .spec.replicas
```

And straight from the database, etcd:

```
kubectl -n kube-system exec etcd-lab-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/deployments/default/spotify-api --keys-only
```

**What you see:** the key `/registry/deployments/default/spotify-api`.

See the recent history of what all the controllers did:

```
kubectl get events --sort-by=.lastTimestamp | tail -20
```

**Why:**

- you never start containers yourself
- you write a **record** (what you want) through the API server, and it is stored in etcd
- small programs **watch** these records and act: the scheduler, the controllers, the kubelets
- they keep fixing the difference between what you want and what exists

## Step 28: Clean up

```
kind delete cluster --name lab
```

To leave the lab, type `exit`. To delete the lab container, run this on your laptop:

```
docker rm -f k8s-lab
```

---

## Summary

| Object | One line | Step |
|---|---|---|
| Node | A machine that runs pods | 1 |
| Control plane | API server, etcd, scheduler, controller manager | 2 |
| kubelet | Program on each node that starts containers | 5, 8 |
| Pod | Containers sharing one IP and `localhost`, on one node | 5 to 8 |
| Label / selector | Tags on objects / how objects find each other | 9, 10 |
| ReplicaSet | Keeps N pods running | 9 to 11 |
| Deployment | Manages versions with rolling updates and rollback | 12, 20, 21 |
| Service | One stable name and IP in front of changing pods | 13, 14 |
| CoreDNS | Turns Service names into Service IPs | 13 |
| kube-proxy | Writes rules that send Service traffic to pods | 14 |
| NodePort | Opens one port on every node for outside traffic | 15 |
| Namespace | A folder for objects | 16 |
| ConfigMap / Secret | Settings kept outside the image | 17, 18 |
| Probes | Readiness = gets traffic? Liveness = restart it? | 19 |
| Requests / limits | Used for placing pods / enforced by cgroups | 22, 23 |
| Self-healing | Pods move off a dead node | 24 |
| HPA | Changes the number of pods based on load | 25 |
| Job | Runs a task once until it succeeds | 26 |
| etcd | Where every object is stored | 27 |

## Pod states you will meet

| State | Meaning | Look at |
|---|---|---|
| `Pending` | No node chosen yet (not enough CPU or memory) | `kubectl describe pod` Events |
| `ContainerCreating` | Node chosen, image or volumes being prepared | `kubectl describe pod` |
| `ImagePullBackOff` | The image cannot be downloaded | Image name, registry access |
| `Running` but `0/1` | Started, but readiness check failing | Readiness probe |
| `CrashLoopBackOff` | Keeps crashing, restarted with growing waits | `kubectl logs <pod> --previous` |
| `OOMKilled` | Went over its memory limit | `resources.limits.memory` |
| `Completed` | Finished successfully (Jobs) | `kubectl logs` |

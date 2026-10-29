# Part 1: Processes, Namespaces and Docker Networking

In this part you will see, step by step:

1. What a process is
2. How Linux namespaces give a process its own private view
3. How cgroups limit what a process can use
4. That a container is just a process with namespaces and cgroups
5. How Docker gives containers their own IP addresses and names
6. How to build a "pod" by hand, which leads into Part 2

Type every command exactly as shown. Each step says what you should see and why.

---

## Step 0: Start the lab (on your laptop)

1. Install Docker Desktop and start it.
   In Docker Desktop, open **Settings > Resources** and give it at least **4 CPUs and 4 GB memory**.

2. Download the lab image:

   ```
   docker pull eshaan0/k8s-skill-lab:1.0
   ```

3. Start the lab container:

   ```
   docker run -d --privileged --name k8s-lab -p 8080:8080 -p 8081:8081 -p 30080:30080 eshaanmathur/k8s-skill-lab:1.0
   ```

   `--privileged` is needed because the lab runs its own Docker and its own Kubernetes inside.

4. Open a shell inside the lab:

   ```
   docker exec -it k8s-lab bash
   ```

   The first time, it prints **"Preparing the lab..."** for about a minute, then **"Lab is ready."**

From now on, type every command **inside this lab shell**. The prompt looks like `lab:/lab#`.

If you close the shell, run `docker exec -it k8s-lab bash` again to come back.

---

# Part A: A process

## Step 1: See the running processes

```
ps -ef
```

**What you see:** a list of programs. Each one has a **PID** (process ID).

**Why:** every running program is a process. The kernel gives each one a number.

## Step 2: Two processes cannot use the same port

Start a small web server on port 5000 in the background:

```
python3 -m http.server 5000 &
```

Try to start a second one on the same port:

```
python3 -m http.server 5000
```

**What you see:** an error ending in `OSError: [Errno 98] Address in use`

**Why:** the machine has **one** table of ports. Port 5000 already belongs to the first process.

Stop the first server:

```
pkill -f "http.server 5000"
```

---

# Part B: Namespaces (what a process can see)

A namespace gives a process its **own private copy** of something: its own process list, its own hostname, its own network.

## Step 3: PID namespace (own process list)

```
unshare --pid --fork --mount-proc ps -ef
```

**What you see:** only **one** process, `ps -ef`, with **PID 1**.

**Why:** `ps` ran inside a new PID namespace. It cannot see any other process on the machine.

## Step 4: UTS namespace (own hostname)

```
hostname
```

```
unshare --uts sh -c 'hostname my-own-name; hostname'
```

```
hostname
```

**What you see:** inside, the hostname is `my-own-name`. Outside, it did not change.

**Why:** the process had its own private hostname.

## Step 5: Network namespace (own network)

Create a network namespace called `red`:

```
ip netns add red
```

Look at its network:

```
ip netns exec red ip addr
```

**What you see:** `lo` (loopback) and a few unused tunnel devices. All of them are `DOWN`, and none has an IP address.

**Why:** a new network namespace starts **empty**.

## Step 6: Connect two namespaces by hand (what Docker does for you)

Create a second namespace, `blue`:

```
ip netns add blue
```

Create a **bridge**. It is a virtual network switch inside the kernel:

```
ip link add br0 type bridge
ip addr add 10.10.0.1/24 dev br0
ip link set br0 up
```

Allow traffic across this bridge (Docker's firewall blocks unknown bridges):

```
iptables -I FORWARD -i br0 -o br0 -j ACCEPT
```

Connect `red` to the bridge with a **veth pair**. A veth pair is a virtual cable with two ends:

```
ip link add veth-red type veth peer name eth0-red
ip link set eth0-red netns red
ip link set veth-red master br0 up
ip netns exec red ip addr add 10.10.0.2/24 dev eth0-red
ip netns exec red ip link set eth0-red up
ip netns exec red ip link set lo up
```

Do the same for `blue`:

```
ip link add veth-blue type veth peer name eth0-blue
ip link set eth0-blue netns blue
ip link set veth-blue master br0 up
ip netns exec blue ip addr add 10.10.0.3/24 dev eth0-blue
ip netns exec blue ip link set eth0-blue up
ip netns exec blue ip link set lo up
```

Look at `red` again:

```
ip netns exec red ip addr show eth0-red
```

**What you see:** `red` now has the IP address `10.10.0.2`.

Ping `blue` from `red`:

```
ip netns exec red ping -c 2 10.10.0.3
```

**What you see:** replies from `10.10.0.3`.

**Why:** you just built, by hand, what Docker builds for every container: a namespace, a veth cable, a bridge, and a private IP address.

## Step 7: The same port in two namespaces

Start a web server on port 5000 inside **each** namespace:

```
ip netns exec red python3 -m http.server 5000 &
ip netns exec blue python3 -m http.server 5000 &
```

**What you see:** no error this time. Both started.

Check which ports are open inside `red`:

```
ip netns exec red ss -ltn
```

Call both servers:

```
curl -s 10.10.0.2:5000 | head -3
curl -s 10.10.0.3:5000 | head -3
```

**What you see:** both answer.

**Why:** each network namespace has its **own** port table. In Step 2 this failed because both servers shared one network.

## Step 8: Clean up the namespaces

```
pkill -f "http.server 5000"
ip netns delete red
ip netns delete blue
ip link delete br0
iptables -D FORWARD -i br0 -o br0 -j ACCEPT
```

---

# Part C: A container is a process

The lab already has some images loaded, so you do not need internet.

## Step 9: See the images

```
docker images
```

**What you see:** `busybox`, `python`, `kindest/node` and others.

## Step 10: Start two containers

```
docker run -d --name c1 busybox:1.36 sleep 3600
docker run -d --name c2 busybox:1.36 sleep 3600
```

Find the container's process from the outside:

```
ps -ef | grep "sleep 3600"
```

**What you see:** two normal `sleep 3600` processes, with normal PIDs.

Now look from the inside:

```
docker exec c1 ps -ef
```

**What you see:** `sleep 3600` has **PID 1**. You cannot see any other process.

```
docker exec c1 hostname
docker exec c1 ls /
```

**What you see:** its own hostname and its own files (from the busybox image).

**Why:** a container is a **normal process** with its own namespaces (PID, hostname, files, network). From outside it is just `sleep`. From inside it looks like a whole machine.

## Step 11: `docker exec` adds a process to the container

Look at the processes in `c1` again:

```
docker exec c1 ps -ef
```

**What you see:** `sleep 3600` (PID 1) and `ps -ef`. The `ps` process has parent PID `0`.

**Why:** `docker exec` starts a **new process** and puts it into the container's existing namespaces. Its real parent lives outside the container, so the container sees parent `0`.

## Step 12: cgroups (limits on CPU and memory)

Start a container with limits:

```
docker run -d --name limited --memory 100m --cpus 0.5 busybox:1.36 sleep 3600
```

Read the limits the kernel is using:

```
docker exec limited cat /sys/fs/cgroup/memory.max
docker exec limited cat /sys/fs/cgroup/cpu.max
```

**What you see:**

- `104857600` = 100 MB of memory
- `50000 100000` = 50 ms of CPU every 100 ms = half a CPU

Now run a program that tries to use 200 MB with a 50 MB limit:

```
docker run --name hog --memory 50m python:3.12-slim python -c "x = bytearray(200 * 1024 * 1024)"
```

```
docker inspect hog --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}'
```

**What you see:** `OOMKilled=true ExitCode=137`

**Why:** **namespaces** control what a process can **see**. **cgroups** control how much it can **use**. Going over the memory limit makes the kernel kill the process.

---

# Part D: Build our app image

Our app is a small music API, like a mini Spotify. It is written in Python with Flask.

## Step 13: Look at the app and its Dockerfile

```
cd /lab/spotify-api
ls
cat Dockerfile
```

**What you see:**

- `app.py` is the program
- `wheels` holds the Python libraries, so the build works without internet
- `Dockerfile` is the recipe to build the image

## Step 14: Build the image

```
docker build -t spotify-api:v1 .
```

```
docker images spotify-api
```

**What you see:** a new image `spotify-api:v1`.

```
docker history spotify-api:v1
```

**What you see:** the image is made of **layers**, one for each step in the Dockerfile.

**Why:** an image is a package of files: Python, libraries and our code. A container started from it sees these files as its whole filesystem.

---

# Part E: Docker networking

## Step 15: Every container has its own IP address

```
docker exec c1 ip addr show eth0
docker exec c2 ip addr show eth0
```

**What you see:** `c1` has `10.200.0.2` and `c2` has `10.200.0.3`.

Look at the bridge and the cables on the lab machine:

```
ip addr show docker0
ip link show master docker0
```

**What you see:**

- `docker0` is a bridge with the address `10.200.0.1`
- `veth...` interfaces are plugged into it, one for each running container

Ping `c2` from `c1` using its IP address:

```
docker exec c1 ping -c 2 10.200.0.3
```

**What you see:** replies.

**Why:** this is exactly Step 6, done by Docker: one namespace per container, one veth cable per container, one bridge.

## Step 16: Names do not work on the default network

```
docker exec c1 ping -c 1 c2
```

**What you see:** `bad address 'c2'`

**Why:** the default Docker network has no name lookup. You would have to use IP addresses.

## Step 17: A custom network gives you names (DNS)

Create a network and start two copies of our app, plus a client:

```
docker network create music
docker run -d --name api1 --network music spotify-api:v1
docker run -d --name api2 --network music spotify-api:v1
docker run -d --name client --network music busybox:1.36 sleep 3600
sleep 2
```

See where the client sends its name lookups:

```
docker exec client cat /etc/resolv.conf
```

**What you see:** `nameserver 127.0.0.11`. This is Docker's own small DNS server.

Look up a name:

```
docker exec client nslookup api1
```

**What you see:** the IP address of `api1`.

Call the API by name:

```
docker exec client wget -qO- api1:5000/songs/most-listened
docker exec client wget -qO- api2:5000/artists/top
```

**What you see:** JSON with songs and artists. Look for Kishore Kumar in the most-listened songs.

**Why:**

- containers on the same custom network can find each other **by name**
- `api1` and `api2` both listen on port **5000** with no clash, because each has its **own** network namespace

## Step 18: DNS gives an IP address, not a port

```
docker exec client wget -qO- api1/
```

**What you see:** `Connection refused`

**Why:** with no port in the URL, `wget` uses port **80**. The app listens on **5000**. DNS only turns the name into an IP address. The port always comes from the URL.

## Step 19: The IP changes, the name keeps working

```
docker exec client nslookup api1
```

Remember the IP address. Now replace `api1`:

```
docker rm -f api1
docker run -d --name filler --network music busybox:1.36 sleep 3600
docker run -d --name api1 --network music spotify-api:v1
sleep 2
```

```
docker exec client nslookup api1
docker exec client wget -qO- api1:5000/
```

**What you see:** `api1` has a **different** IP address now, but calling it by name still works.

**Why:** Docker's DNS always answers with the **current** IP address of the container. Never use container IP addresses directly.

## Step 20: Publish a port so the outside can reach a container

```
docker run -d --name public-api -p 8080:5000 spotify-api:v1
sleep 2
```

```
curl -s localhost:8080/songs/most-listened
```

**What you see:** the JSON response.

On your laptop, open this in a browser: **http://localhost:8080/songs/most-listened**

See the rule Docker added to the kernel's firewall:

```
iptables -t nat -S DOCKER | grep 8080
```

**What you see:** a `DNAT` rule: traffic to port 8080 is sent to the container's IP address on port 5000.

Try to publish the same port again:

```
docker run -d --name public-api2 -p 8080:5000 spotify-api:v1
```

**What you see:** an error that port 8080 is already allocated.

**Why:**

- container IP addresses are private to this machine
- to reach a container from outside, Docker forwards one port of the machine to the container
- the machine has only one port 8080, so only one container can use it

## Step 21: Build a "pod" by hand

A pod in Kubernetes is a group of containers that **share one network**. Let us build one with plain Docker.

Start a container that only holds the network:

```
docker run -d --name pod-holder --network music busybox:1.36 sleep 3600
```

Start the app and a helper, and make both **join** the holder's network:

```
docker run -d --name pod-app --network container:pod-holder spotify-api:v1
docker run -d --name pod-helper --network container:pod-holder busybox:1.36 sleep 3600
sleep 2
```

Compare their IP addresses:

```
docker exec pod-holder ip addr show eth0
docker exec pod-helper ip addr show eth0
```

**What you see:** the **same** IP address.

The helper can reach the app on `localhost`:

```
docker exec pod-helper wget -qO- localhost:5000/songs/most-listened
```

**What you see:** the songs list. Its `served_by` is the ID of `pod-holder`, because the containers also share the hostname.

But the helper cannot see the app's processes or files:

```
docker exec pod-helper ps -ef
docker exec pod-helper ls /app
```

**What you see:** only `sleep` in the process list, and `/app` does not exist.

**Why:**

- the three containers share **one network namespace** (one IP address, one set of ports, one `localhost`) and one hostname
- each container still has its **own** files and processes
- this is exactly what a **pod** is. Kubernetes does these same steps for you. The "holder" container is called the **pause** container.

## Step 22: Clean up

```
docker rm -f c1 c2 limited hog api1 api2 client filler public-api public-api2 pod-holder pod-app pod-helper
docker network rm music
cd /lab
```

---

## Summary

| Idea | What it means | Where you saw it |
|---|---|---|
| Process | A running program with a PID | Step 1 |
| One port table | Two processes on one network cannot use the same port | Step 2 |
| Namespace | A private view: own processes, hostname, network | Steps 3 to 7 |
| veth + bridge | How namespaces get connected and get IP addresses | Step 6, Step 15 |
| cgroup | Limits on CPU and memory | Step 12 |
| Container | A process + namespaces + cgroups + image files | Steps 10 to 12 |
| Image | A package of files, built in layers | Step 14 |
| Docker DNS | Container names turn into current IP addresses | Steps 17 to 19 |
| Port publishing | A machine port forwarded to a container | Step 20 |
| Pod | Containers sharing one network namespace | Step 21 |

**Next:** open Part 2.

```
less /lab/README-2-kubernetes-from-scratch.md
```

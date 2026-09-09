# Inception-of-Things — Personal Reference Guide

A from-scratch explanation of everything covered while building Part 1 (K3s + Vagrant) and Part 2 (Deployments, Services, ConfigMaps, Ingress). Written so you can come back to any section without re-deriving it from a conversation.

---

## Table of Contents

1. [The Big Picture: Cluster, Node, API Object](#1-the-big-picture)
2. [Part 1 — Vagrant Networking](#2-part-1--vagrant-networking)
3. [Part 1 — Control Plane vs Agent](#3-part-1--control-plane-vs-agent)
4. [Part 1 — The Join Sequence](#4-part-1--the-join-sequence)
5. [Part 2 — How kubectl apply Actually Works](#5-part-2--how-kubectl-apply-actually-works)
6. [Part 2 — Pod](#6-part-2--pod)
7. [Part 2 — Deployment, Field by Field](#7-part-2--deployment-field-by-field)
8. [Part 2 — Service, Field by Field](#8-part-2--service-field-by-field)
9. [Part 2 — CoreDNS](#9-part-2--coredns)
10. [Part 2 — ConfigMap, Field by Field](#10-part-2--configmap-field-by-field)
11. [Part 2 — Ingress, Field by Field](#11-part-2--ingress-field-by-field)
12. [The Full Chain, End to End](#12-the-full-chain-end-to-end)
13. [kubectl Command Cheat Sheet](#13-kubectl-command-cheat-sheet)
14. [Gotchas Actually Hit While Building This](#14-gotchas-actually-hit-while-building-this)

---

## 1. The Big Picture

Kubernetes is, underneath everything, just **a database plus a set of programs that react to what's in it**.

```
 ┌─────────────────────────────────────────────────────────┐
 │                        CLUSTER                           │
 │   (your two VMs, working together as one system)         │
 │                                                            │
 │   ┌────────────────────┐      ┌────────────────────┐    │
 │   │   NODE: mezzineS    │      │  NODE: mezzineSW    │    │
 │   │   (control-plane)   │      │  (worker)            │    │
 │   └────────────────────┘      └────────────────────┘    │
 └─────────────────────────────────────────────────────────┘
```

Every YAML file you write — Deployment, Service, ConfigMap, Ingress — is called an **API object**. All of them share the exact same shape and go through the exact same pipeline:

```
 kubectl apply -f file.yaml
         │
         ▼
 ┌───────────────┐        ┌───────────────┐
 │  API SERVER   │──────▶│   DATASTORE    │   (SQLite via "kine", in K3s)
 │  (port 6443)  │◀──────│  (the record   │
 └───────────────┘        │  is now real)  │
                            └───────────────┘
         │
         ▼
 Background "watcher" programs notice the change and react —
 but ONLY to the "kind" they care about:

   kind: Deployment  →  controller-manager creates Pods
   kind: Service     →  kube-proxy writes iptables rules
   kind: ConfigMap   →  kubelet mounts it when a pod starts
   kind: Ingress     →  Traefik updates its routing rules
```

Every object, regardless of kind, has the same four top-level fields:

```yaml
apiVersion: ...   # which schema/rulebook this object follows
kind: ...         # WHAT kind of object — decides who reacts to it
metadata: ...     # name, labels — its identity
spec: ...         # the actual desired state — different per kind
```

---

## 2. Part 1 — Vagrant Networking

Every VM gets **two** network interfaces (NICs):

```
                    ┌─────────────────────────────┐
                    │      YOUR VM (mezzineS)       │
                    │                               │
   Internet ◀──────▶│  NIC 0 (NAT)                  │
   (apt-get,        │  IP: 10.0.2.15 (same on both  │
    curl installs)   │  VMs — but ISOLATED per VM,   │
                    │  outbound-only)               │
                    │                               │
   Other VMs +  ◀──▶│  NIC 1 (private_network)      │
   Host machine     │  IP: 192.168.56.110 (static,  │
                    │  set by YOU in Vagrantfile)   │
                    └─────────────────────────────┘
```

- **NAT (NIC 0):** each VM gets its own *isolated* NAT instance. Two VMs showing the same `10.0.2.15` is a coincidence of defaults, not a shared network — VM A literally cannot reach VM B over this NIC. Its only job is outbound internet access (installing packages).
- **Private network (NIC 1):** a real, shared virtual switch connecting your host + all sibling VMs. This is the *only* path VMs use to reach each other, and the *only* IP the subject's grading (`192.168.56.110`/`.111`) cares about.

```ruby
vb.vm.network "private_network", ip: "192.168.56.110"
# netmask defaults to 255.255.255.0 (== /24) if you don't set one —
# meaning addresses 192.168.56.0–192.168.56.255 are all on this subnet
```

---

## 3. Part 1 — Control Plane vs Agent

```
 ┌───────────────────────────────┐   ┌───────────────────────────────┐
 │   SERVER MODE (mezzineS)       │   │   AGENT MODE (mezzineSW)       │
 │   = "the brain"                │   │   = "the muscle"               │
 │                                │   │                                │
 │  • API server (port 6443)      │   │  • kubelet — runs whatever     │
 │  • datastore (SQLite/kine)     │   │    pods get assigned to it     │
 │  • scheduler — picks WHICH     │   │  • containerd — actually       │
 │    node runs a new pod         │   │    pulls images, runs          │
 │  • controller-manager —        │   │    containers                 │
 │    reconciles desired vs       │   │  • kube-proxy — writes         │
 │    actual state                │   │    iptables rules for          │
 │                                │   │    Services (built into the   │
 │  NOTE: unless --disable-agent  │   │    k3s binary in K3s, not a   │
 │  is passed, a K3s SERVER also  │   │    separate process)          │
 │  runs its own local agent —    │   │  • flannel — pod-to-pod        │
 │  it's brain AND muscle at once │   │    overlay networking          │
 └───────────────────────────────┘   └───────────────────────────────┘
```

---

## 4. Part 1 — The Join Sequence

This is what happens the moment `mezzineSW` boots and its agent provisioning script runs.

```
  WORKER                                          SERVER
    │                                                │
    │ 1. Starts local proxy 127.0.0.1:6444          │
    │    (forwards to 192.168.56.110:6443)          │
    │                                                │
    │ 2. Sends join TOKEN ───────────────────────▶  │
    │                                                │  validates token
    │                                                │
    │ 3. ◀─────────────── issues a UNIQUE signed    │
    │    receives its own TLS client certificate     │  TLS certificate
    │    (this is the ACTUAL trust-establishment      │  ("certificate
    │    moment — token is never used again after     │  CN=mezzinesw
    │    this)                                        │  signed by...")
    │                                                │
    │ 4. Uses cert to fetch full bootstrap config   │
    │    (CA cert, kubelet serving cert, runtime     │
    │    config) — GET /v1-k3s/config, etc.          │
    │                                                │
    │ 5. kubelet REGISTERS as a Node                │
    │    ──▶ this is the moment `kubectl get nodes`  │
    │        first shows mezzinesw                   │
    │                                                │
    │ 6. ONGOING, forever:                          │
    │    kubelet WATCHES api-server for pods         │
    │    assigned to this node, runs them via        │
    │    containerd, and sends periodic HEARTBEATS   │
    │    (lease renewals) to prove it's alive         │
    ▼                                                ▼
```

**Real bug hit here:** on a 1 CPU / 1GB VM, the control plane can be so overloaded bootstrapping its own system pods (coredns, traefik, metrics-server) that it times out responding to the worker's `/v1-k3s/config` requests — producing an infinite, harmless-looking retry loop (`context deadline exceeded`) that looks like a network/auth failure but is actually just resource starvation. Confirmed by finding `certificate CN=mezzinesw signed by...` in the *server's* own logs — proof the handshake was progressing the whole time, just slowly.

---

## 5. Part 2 — How `kubectl apply` Actually Works

```
 1. kubectl reads your local .yaml file
 2. Converts it to JSON
 3. Sends it as an HTTPS POST to the API server (port 6443)
 4. API server validates it against that "kind"'s schema
 5. Writes it into the datastore  ─────▶  object now EXISTS,
                                            but nothing is
                                            RUNNING yet
 6. controller-manager notices a new Deployment wants N pods,
    but 0 exist → creates Pod object(s) (still just DB records)
 7. scheduler notices a Pod has no node assigned → picks one,
    writes that decision back
 8. kubelet on the CHOSEN node notices "a pod is assigned to
    me" → tells containerd to pull the image and start it

    ONLY NOW does a real running container exist anywhere.
```

Watch it happen live: `kubectl get pods -w`
```
NAME                 READY   STATUS              AGE
app1-...             0/1     Pending             1s   (steps 6-7)
app1-...             0/1     ContainerCreating   2s   (step 8, pulling image)
app1-...             1/1     Running             8s   (fully alive)
```

---

## 6. Part 2 — Pod

The smallest unit Kubernetes actually **runs**. Not the same as a container:

```
 ┌─────────────────────────────────────────┐
 │                  POD                      │
 │   • ONE IP address for the whole pod       │
 │   • Lives on exactly ONE node              │
 │   • Usually wraps exactly ONE container    │
 │     (can hold more, e.g. app + sidecar,    │
 │     but that's the exception, not the      │
 │     norm for this project)                 │
 │                                            │
 │   ┌─────────────────────────────────┐    │
 │   │         CONTAINER                 │    │
 │   │   (the actual running process,    │    │
 │   │    e.g. nginx)                     │    │
 │   └─────────────────────────────────┘    │
 └─────────────────────────────────────────┘
```

**Bare `kind: Pod`** — no supervisor watching it. Delete it → gone forever. Only useful for throwaway debugging tools (e.g. a `sleep infinity` busybox pod you `exec` into).

**Pods created by a Deployment** — delete one → the Deployment's controller notices "0/1 replicas" and immediately creates a replacement (new random name, new IP). This is the entire practical difference between the two.

Naming pattern for Deployment-managed pods:
```
<deployment-name> - <template-hash> - <random-suffix>
     app1        -   5cf695695c     -    gxv7d
```
Changing a Deployment's `metadata.name` and reapplying does **not** rename the existing object — it creates a brand-new, separate Deployment. The old one (and its pods) keeps existing unless explicitly deleted.

---

## 7. Part 2 — Deployment, Field by Field

```yaml
apiVersion: apps/v1              # Deployment lives in the "apps" API group
kind: Deployment
metadata:
  name: app1                     # THIS object's unique identity
  labels:
    app: app1                    # tag on the Deployment itself (for YOUR filtering)
spec:
  replicas: 1                    # "how many pods should exist, ALWAYS" —
                                  # read continuously by controller-manager
  selector:
    matchLabels:
      app: app1                  # HOW this Deployment recognizes its own pods —
                                  # MUST match template.metadata.labels below,
                                  # or kubectl apply is REJECTED
  template:                      # the exact blueprint copied every time a
                                  # new pod needs creating
    metadata:
      labels:
        app: app1                # stamped onto every REAL pod created —
                                  # this is what Services later match against
    spec:
      containers:
        - name: app1             # container's name WITHIN this pod
          image: nginx:alpine    # image to pull and run
          ports:
            - containerPort: 80  # documents what port the app listens on
                                  # inside the container (informational —
                                  # doesn't open anything by itself)
          volumeMounts:
            - name: web-apps           # must match a "volumes:" name below
              mountPath: /usr/share/nginx/html/index.html   # WHERE it appears
              subPath: index.html      # WHICH key to place there (avoids
                                        # wiping the whole target directory)
      volumes:
        - name: web-apps          # local name, referenced by volumeMounts above
          configMap:
            name: app1-html       # the ACTUAL data source — a DIFFERENT,
                                   # separate ConfigMap object
```

**The reconcile loop**, running continuously in the background:
```
 while cluster.is_running:
     current = count_pods(label="app: app1")
     if current < replicas:  create_pod()      # crash / first creation
     if current > replicas:  delete_extra()    # you scaled down
```

`kubectl get deployment` reports on the **desired-state object** (READY = current/desired, e.g. `3/3`).
`kubectl get pods` reports on the **actual running instances** (one row per real pod, each independently trackable).

---

## 8. Part 2 — Service, Field by Field

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app1-svc
spec:
  selector:
    app: app1                 # matches POD LABELS directly. Has ZERO
                               # awareness that a Deployment even exists —
                               # it just happens to line up because the
                               # Deployment's template put this label on
                               # its pods
  ports:
    - port: 8080               # what OTHER things in the cluster call
                                # THIS SERVICE on
      targetPort: 80           # where it forwards to on the actual pod —
                                # must match containerPort above
```

**Why Service exists — the problem it solves:**
```
 Without a Service:  pod IPs change every time a pod restarts/
                     reschedules → nothing can reliably reach them

 With a Service:     ONE fixed ClusterIP, forever, for the object's
                     whole life — the list of pods BEHIND it
                     updates automatically, silently, in real time
```

**How routing actually happens** (this part surprises people — it's not a live process making per-request decisions):

```
 1. kube-proxy (baked into the k3s binary in K3s — not a separate
    process) CONTINUOUSLY watches the API server for this
    Service's matching pods

 2. It PRE-WRITES iptables rules ahead of time:
    "traffic to 10.43.171.213 → randomly forward to one of
     [pod IP 1, pod IP 2, pod IP 3]"

 3. When a request actually arrives, the LINUX KERNEL itself
    executes the already-written rule — no live decision-making
    process is "in the middle" at request time
```

Confirmed with your own test: deleting the pod behind a Service and re-querying it *still worked*, unchanged — proof the Service's address is stable regardless of which pods are currently behind it.

`ClusterIP` (the default type) is only reachable **from inside the cluster** — not from your host machine. That gap is what Ingress solves (Section 11).

---

## 9. Part 2 — CoreDNS

A real, separate pod (`kube-system` namespace) that's a genuine DNS server — same concept as any internet DNS server, just scoped to names inside your cluster.

```
 ┌───────────────────────────────────────────────┐
 │  EVERY POD, at creation time, gets its         │
 │  /etc/resolv.conf automatically pointed at:     │
 │       nameserver 10.43.0.10    (coredns)        │
 │  — set ONCE by kubelet, unrelated to whether    │
 │  any Service exists yet or not                  │
 └───────────────────────────────────────────────┘

 ┌───────────────────────────────────────────────┐
 │  CREATING a Service does NOT touch any pod's    │
 │  resolv.conf at all. It adds ONE NEW RECORD      │
 │  inside coredns's own internal table:            │
 │       "app1-svc" → 10.43.171.213                │
 │  DELETING the Service removes that record —      │
 │  the pod's file is still byte-for-byte the same  │
 └───────────────────────────────────────────────┘
```

Important nuance: this is **not** an access restriction, just a default. The node itself (not a pod) has its own unrelated `/etc/resolv.conf` — Kubernetes never touches it. You can still query coredns directly from the node:
```bash
nslookup app1-svc 10.43.0.10     # works from the NODE too — proves
                                  # it's about which DNS server is
                                  # ASKED, not about "being inside a pod"
```

Find coredns's address: `kubectl get svc -n kube-system kube-dns`

---

## 10. Part 2 — ConfigMap, Field by Field

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app1-html            # unique identity — referenced BY THIS NAME
                              # from a Deployment's volumes section
data:
  index.html: |               # "|" = keep this multi-line block exactly
                               # as-is, including line breaks
    <html><body><h1>Hello from app1</h1></body></html>
```

Purely a bucket of text, stored in the cluster's database — **no image, no ports, runs nothing on its own.** Its entire purpose: separate configuration/content from the container image, so content can change without rebuilding anything.

```
 ConfigMap "app1-html"  (just data, sitting in the cluster)
        │
        │ referenced by NAME in Deployment's "volumes:"
        ▼
 Deployment's pod template exposes it as a virtual volume
        │
        │ "volumeMounts" places ONE key from it at an
        │ EXACT file path inside the container
        ▼
 nginx just opens /usr/share/nginx/html/index.html like any
 normal file — has NO idea it came from a ConfigMap at all
```

Generate one from a real local file instead of hand-typing content:
```bash
kubectl create configmap app1-html --from-file=index.html=app1.html \
  --dry-run=client -o yaml > app1-configmap.yaml
```

**Real bug hit here:** serving static files via `hostPath` pointed at a VirtualBox shared folder (`/vagrant`, backed by `vboxsf`) truncated responses (`curl: (18) end of response... bytes missing`) — a known incompatibility between nginx's `sendfile` kernel optimization and the `vboxsf` filesystem's incorrect EOF reporting. Fixed by switching to a ConfigMap-backed volume instead, which sidesteps the host filesystem entirely.

---

## 11. Part 2 — Ingress, Field by Field

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apps-ingress
spec:
  rules:
    - host: app1.com                 # match against the incoming HTTP
                                      # "Host:" header specifically
      http:
        paths:
          - path: /
            pathType: Prefix         # "/" as a prefix = ANY path under
                                      # it matches (e.g. /foo, /bar too)
            backend:
              service:
                name: app1-svc       # WHICH Service to send matching
                                      # traffic to
                port:
                  number: 8080       # WHICH port on that Service
  defaultBackend:                    # the FALLBACK — ANY request that
    service:                         # matches NO rule above (wrong host,
      name: app3-svc                 # or no Host header at all) lands
      port:                          # here instead
        number: 8080
```

Ingress is **not a running process** — it's just routing rules, same as everything else, an API object. The thing that actually *does* the routing is an **Ingress controller**: a real pod that watches Ingress objects and configures itself accordingly. K3s ships one by default — **Traefik** — already installed the moment the K3s server first came up (`job.batch/helm-install-traefik` in your very first Part 1 logs).

Traefik's Service is type `LoadBalancer` (auto-provisioned via K3s's ServiceLB) — this is what actually opens ports 80/443 directly on the node's own IP (`192.168.56.110`), making it reachable from your **host machine**, unlike a plain `ClusterIP`.

Test from your **host**, not inside the VM:
```bash
curl -H "Host: app1.com" http://192.168.56.110
```

---

## 12. The Full Chain, End to End

```
 ConfigMap "app1-html"
    (holds the HTML text)
        │
        │  referenced by NAME
        ▼
 Deployment "app1"  (labels its pods: app=app1)
        │
        │  matched by LABEL
        ▼
 Service "app1-svc"  (stable ClusterIP, listens :8080 → pod's :80)
        │
        │  referenced by NAME + PORT
        ▼
 Ingress "apps-ingress"  (routes Host: app1.com → app1-svc)
        │
        │  actually enforced by
        ▼
 Traefik (the running Ingress controller pod)
        │
        │  exposed on the node's real IP via a LoadBalancer Service
        ▼
 Reachable from your HOST machine at 192.168.56.110,
 with Host header "app1.com"
```

Every arrow above is a **name matching a name, or a label matching a label** — written explicitly, by hand, in YAML. Nothing auto-discovers anything; a typo anywhere in this chain silently breaks exactly that one link (e.g. wrong label in a Service's selector = it finds zero pods, but the Service object itself still "applies" successfully with no error).

---

## 13. kubectl Command Cheat Sheet

| Want to... | Command |
|---|---|
| See cluster nodes | `kubectl get nodes -o wide` |
| See current state | `kubectl get pods` / `kubectl get deployment` / `kubectl get svc` / `kubectl get ingress` |
| See everything at once | `kubectl get all` |
| Debug why something's wrong | `kubectl describe pod <name>` |
| See app's own console output | `kubectl logs <pod-name>` (add `-f` to follow live) |
| Get a shell inside a running pod | `kubectl exec -it <pod-name> -- sh` |
| Tunnel a port straight to one pod (bypasses Service/Ingress) | `kubectl port-forward pod/<name> 8080:5678` |
| Force-restart a Deployment cleanly (no downtime gap) | `kubectl rollout restart deployment <name>` |
| Change replica count on the fly | `kubectl scale deployment <name> --replicas=N` |
| Apply/update from YAML | `kubectl apply -f <file>.yaml` |
| Remove everything defined in a file | `kubectl delete -f <file>.yaml` |
| Delete a single pod (respawns if Deployment-managed!) | `kubectl delete pod <name>` |
| Delete without waiting for graceful shutdown | `kubectl delete pod <name> --wait=false` |
| Force-delete a truly stuck pod | `kubectl delete pod <name> --grace-period=0 --force` |
| Watch changes live instead of a one-time snapshot | add `-w` to any `get` command |
| Generate a ConfigMap from a real file | `kubectl create configmap <name> --from-file=key=file --dry-run=client -o yaml > out.yaml` |

---

## 14. Gotchas Actually Hit While Building This

1. **Duplicate private-network IP** — both VMs accidentally set to `.110` caused an unusable network; each node needs its own unique static IP.
2. **Stale provisioning** — editing a Vagrantfile's `provision` block does **nothing** to a VM that already exists. `vagrant up` only re-runs provisioners on first creation. Use `vagrant destroy -f && vagrant up` while iterating, or `vagrant reload --provision` to reapply without a full rebuild.
3. **Token mismatch** — worker joining with a hardcoded token while the server (rebuilt without that flag) generated a fresh random one → authentication silently retried forever instead of failing loud.
4. **Control-plane resource starvation** — 1 CPU/1GB is genuinely tight for K3s bootstrapping all its default system pods at once; can cause join requests to time out repeatedly even though the handshake is actually succeeding, just slowly. Confirmed by checking the *server's* logs for the actual certificate-signing line, not just the worker's timeout messages.
5. **NAT vs private network confusion** — `curl`/`ping` tests against `10.0.2.15` (NAT) prove nothing about node-to-node connectivity; only the `192.168.56.x` private-network IP matters for cluster communication.
6. **kubectl "hanging" on delete** — it's not stuck; `kubectl delete pod` blocks by default until the pod's graceful-shutdown grace period (default 30s) actually finishes. `--wait=false` returns immediately if you don't need to watch.
7. **vboxsf + nginx `sendfile` bug** — serving static files from a VirtualBox shared folder (`hostPath` → `/vagrant`) via nginx can truncate responses. ConfigMap-backed volumes avoid the host filesystem entirely and sidestep this.
8. **Renaming a Deployment isn't a rename** — changing `metadata.name` and reapplying creates a brand-new, separate object; the old one (and its pods) keeps running unless explicitly deleted, leading to accidental duplicates.
9. **DNS only works "for free" inside pods** — a node's own shell has a completely separate, Kubernetes-untouched `/etc/resolv.conf`; Service *names* only resolve automatically inside pods (or by explicitly pointing a query at coredns's ClusterIP manually).

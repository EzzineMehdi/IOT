# Inception-of-Things — Personal Reference Guide

A from-scratch explanation of everything covered while building Part 1 (K3s + Vagrant), Part 2 (Deployments, Services, ConfigMaps, Ingress), and Part 3 (K3d, Argo CD, GitOps). Written so you can come back to any section without re-deriving it from a conversation.

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
14. [Part 3 — K3d vs K3s](#14-part-3--k3d-vs-k3s)
15. [Part 3 — Namespaces](#15-part-3--namespaces)
16. [Part 3 — GitOps, the Concept](#16-part-3--gitops-the-concept)
17. [Part 3 — Installing Argo CD](#17-part-3--installing-argo-cd)
18. [Part 3 — the Application Object](#18-part-3--the-application-object)
19. [Part 3 — the REAL Pod Chain: Deployment → ReplicaSet → Pod](#19-part-3--the-real-pod-chain-deployment--replicaset--pod)
20. [Part 3 — containerPort, Clarified](#20-part-3--containerport-clarified)
21. [Part 3 — Exposing Services from K3d via Ingress](#21-part-3--exposing-services-from-k3d-via-ingress)
22. [p3/ Folder Structure — What Goes Where](#22-p3-folder-structure--what-goes-where)
23. [Gotchas Actually Hit While Building This](#23-gotchas-actually-hit-while-building-this)

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

   kind: Deployment  →  controller-manager creates ReplicaSets
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
    but 0 exist → creates a ReplicaSet, which creates Pod
    object(s) (still just DB records) — see Section 19 for the
    full accurate chain
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

**Pods created by a Deployment** — delete one → the ReplicaSet behind it notices "0/1 replicas" and immediately creates a replacement (new random name, new IP). See **Section 19** for the real naming chain (Deployment → ReplicaSet → Pod) — the simplified two-level version here was corrected once ReplicaSets entered the picture in Part 3.

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
                                  # inside the container — see Section 20,
                                  # this is PURELY documentation
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

`ClusterIP` (the default type) is only reachable **from inside the cluster** — not from your host machine. That gap is what Ingress solves (Section 11, and again for K3d specifically in Section 21).

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

Cross-namespace lookups need the fully-qualified form (see Section 15): `<service>.<namespace>.svc.cluster.local` — `app1-svc` alone only resolves *within the same namespace* as the pod asking.

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

`Secret` (Section 17) is structurally identical to ConfigMap — same `data:` shape, same volume-mounting mechanism — just base64-encoded and treated as sensitive.

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

K3d needs one extra step to get the same result — see Section 21.

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
| Debug why something's wrong | `kubectl describe pod <name>` / `kubectl describe application <name> -n argocd` |
| See app's own console output | `kubectl logs <pod-name>` (add `-f` to follow live) |
| Get a shell inside a running pod | `kubectl exec -it <pod-name> -- sh` |
| Tunnel a port straight to one pod/svc (debug only) | `kubectl port-forward svc/<name> 8080:443` |
| Force-restart a Deployment cleanly (no downtime gap) | `kubectl rollout restart deployment <name>` |
| See rollout/ReplicaSet history | `kubectl rollout history deployment <name>` |
| Change replica count on the fly | `kubectl scale deployment <name> --replicas=N` |
| Apply/update from YAML | `kubectl apply -f <file>.yaml` |
| Apply huge manifests (e.g. Argo CD's CRDs) | `kubectl apply --server-side --force-conflicts -f <url>` |
| Remove everything defined in a file | `kubectl delete -f <file>.yaml` |
| Delete a single pod (respawns if Deployment-managed!) | `kubectl delete pod <name>` |
| Delete without waiting for graceful shutdown | `kubectl delete pod <name> --wait=false` |
| Force-delete a truly stuck pod | `kubectl delete pod <name> --grace-period=0 --force` |
| Watch changes live instead of a one-time snapshot | add `-w` to any `get` command |
| Block until a condition is met (e.g. in scripts) | `kubectl wait --for=condition=Ready pods --all -n <ns> --timeout=300s` |
| Generate a ConfigMap from a real file | `kubectl create configmap <name> --from-file=key=file --dry-run=client -o yaml > out.yaml` |
| Generate a Namespace YAML idempotently | `kubectl create namespace <name> --dry-run=client -o yaml \| kubectl apply -f -` |

---

## 14. Part 3 — K3d vs K3s

K3d is **not** a different Kubernetes distribution — it takes the exact same `k3s` binary from Part 1 and runs it **inside Docker containers** instead of directly on a VM's OS.

```
   PART 1 (what you built)                  PART 3 (K3d)
 ┌─────────────────────────────┐          ┌───────────────────────────────┐
 │   VirtualBox VM               │          │   Docker container             │
 │   (full OS, own kernel)       │          │   (shares host's kernel,       │
 │   running k3s server          │          │   much lighter/faster)         │
 └─────────────────────────────┘          │   running k3s server           │
                                            └───────────────────────────────┘
```

Everything from Sections 1–13 is **still true, unchanged** — control plane, agent, kube-proxy, CoreDNS, Ingress/Traefik, all of it. K3d only changes what a "node" is physically made of (a container instead of a VM), which is why spinning a cluster up/down takes seconds instead of minutes.

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d cluster create mycluster
docker ps   # each "node" is literally just a Docker container
```

`kubectl get nodes -o wide` will show a Docker-network IP (e.g. `172.18.0.2` or `172.20.0.3`) instead of a `192.168.56.x` Vagrant IP — there's no manual IP assignment here, Docker's own networking assigns it.

---

## 15. Part 3 — Namespaces

A namespace **partitions objects within one cluster** into logical groups — same cluster, same nodes, same API server/database, just a labeled subdivision. You've been using one this whole time without naming it:

```bash
kubectl get pods            # secretly short for:
kubectl get pods -n default
```

```
class WhatNamespacesGiveYou:
    def naming_isolation(self):
        # you CAN have the SAME NAME in different namespaces —
        # they're fully separate objects, namespace is part of identity
        return {"argocd ns": "Deployment app1", "dev ns": "Deployment app1"}

    def what_it_does_NOT_do(self):
        # a NAMING/organizational boundary, NOT a hard network wall —
        # a pod in one namespace CAN reach a Service in another,
        # it just needs the fully-qualified DNS name to do it
        return "isolation of NAMES, not isolation of NETWORK access"
```

Create declaratively (preferred, matches everything else you've built):
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev
```

`argocd` holds Argo CD's own machinery (server, repo-server, controller...). `dev` holds the actual application Argo CD deploys for you.

---

## 16. Part 3 — GitOps, the Concept

The shift from Part 1/2's workflow:

```
 OLD (Part 1/2):  you edit YAML → YOU manually run kubectl apply
                  → cluster updates ONLY because a human typed a command

 GITOPS (Part 3): you edit YAML → commit + push to a GIT REPO
                  → a tool RUNNING INSIDE THE CLUSTER continuously
                    watches that repo and runs the apply FOR you
```

Git becomes the single source of truth. If the live cluster ever drifts from what's committed (someone ran `kubectl edit` by hand, or a pod crashed), the watching tool notices the mismatch and reconciles it back — automatically.

This is the **exact same reconcile pattern** as a Deployment (Section 7), just one layer up:

```
 Deployment controller:  desired replica COUNT  vs  actual pods running
 Argo CD:                 desired STATE (the repo) vs  actual cluster state
```

Directly maps to the subject's requirement: edit an image tag in your GitHub repo (`v1` → `v2`), push, and the running app updates **without you ever running `kubectl` yourself**.

---

## 17. Part 3 — Installing Argo CD

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**Why `--server-side --force-conflicts` specifically:** a plain `kubectl apply` stores your entire previous YAML in a `last-applied-configuration` annotation (so it can diff future changes). Argo CD's `applicationsets.argoproj.io` CRD (a schema definition for a custom object type) is big enough that this annotation blows past Kubernetes' hard 262144-byte annotation cap → `"Too long: may not be more than 262144 bytes"`. Server-side apply tracks field ownership on the API server directly instead of stuffing a full copy into an annotation, sidestepping the limit entirely. `--force-conflicts` is needed if you'd already partially applied it the old way first.

One command creates ~12+ objects: `argocd-server` (API + UI), `argocd-repo-server` (clones/reads your Git repos), `argocd-application-controller` (the actual reconcile loop), `argocd-dex-server` (auth), `argocd-redis` (caching) — each its own Deployment, plus several `Secret` objects (see Section 10's note).

Get the auto-generated admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

Quick debug access (see Section 21 for the permanent Ingress-based way instead):
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## 18. Part 3 — the Application Object

A **new kind** Argo CD itself installs (a CRD) — structurally identical to everything you already know (`apiVersion`/`kind`/`metadata`/`spec`), it's just the object that tells Argo CD *what repo to watch* and *where to deploy it*.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: playground-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/<repo>.git   # see note below re: HTTPS vs SSH
    targetRevision: main
    path: .                       # which folder INSIDE the repo holds the manifests
  destination:
    server: https://kubernetes.default.svc   # special URL = "this same cluster"
    namespace: dev                # where the app actually lands
  syncPolicy:
    automated:
      prune: true      # delete from cluster if removed from the repo
      selfHeal: true    # revert manual kubectl edits back to match the repo
```

**Two completely separate systems, easy to conflate at first:**
```
 YOUR GitHub repo (you create it — public, your login in the name)
   → holds YAML FILES ONLY (text/config), read by Argo CD

 wil42/playground:v1 on Docker Hub
   → the actual pre-built CONTAINER IMAGE, referenced by name in
     your Deployment YAML — Wil's account, nothing you upload
```

**Repo must be PUBLIC** — the subject requires it explicitly, and it also means Argo CD needs zero credentials to clone it. Use `https://github.com/...` (not `git@github.com:...`) — the SSH form always needs a configured key even for public repos; HTTPS on a public repo is a plain unauthenticated clone.

A `SYNC STATUS` of `Unknown` (not `OutOfSync`/`Synced`) usually means Argo CD hasn't successfully read the repo yet — check with `kubectl describe application <name> -n argocd` and look at `Conditions`/`Events` for the real reason (private repo, wrong path, nothing pushed yet).

---

## 19. Part 3 — the REAL Pod Chain: Deployment → ReplicaSet → Pod

Correction to the simplified Part 2 model: a Deployment does **not** create Pods directly. There's a layer in between:

```
 Deployment  →  ReplicaSet  →  Pod

 Deployment's real job:  owns/supervises ReplicaSet objects
 ReplicaSet's real job:  ensures exactly N pods exist matching
                         ONE SPECIFIC VERSION of the pod template
```

**Why the split exists:** a ReplicaSet is locked to one exact template version. The moment `spec.template` changes at all (new image tag, new label, anything), the Deployment doesn't edit the existing ReplicaSet — it creates a **brand new** one with the new template, scales it up, and scales the *old* one down to 0 (kept around as rollback history, not deleted):

```
replicaset.apps/wil-playground-66d94f58f4   0   0   0   24m   ← OLD template, scaled to 0
replicaset.apps/wil-playground-7796fcdb67   1   1   1   11m   ← CURRENT template, active
```

This exact mechanism is **how the v1 → v2 rolling update works** for the subject's version-switch requirement.

```bash
kubectl rollout history deployment <name> -n <namespace>
```

**Accurate naming chain:**
```
 <deployment-name>                         wil-playground
      │  + template-hash (computed FROM
      │    the pod template's content)
      ▼
 <deployment-name>-<hash>                  wil-playground-7796fcdb67   (ReplicaSet)
      │  + random suffix, appended
      │    by the REPLICASET, not the
      │    Deployment directly
      ▼
 <replicaset-name>-<random>                wil-playground-7796fcdb67-6fkwm   (Pod)
```

Changing a Deployment's `metadata.name` and reapplying still creates a whole new, separate Deployment (and therefore new ReplicaSet + Pods) — the old one keeps existing unless explicitly deleted (this part of the Part 2 finding still holds).

---

## 20. Part 3 — containerPort, Clarified

```yaml
ports:
  - containerPort: 8888
```

**Does NOT:** open the port, make the app listen, or restrict/firewall anything. The container would listen on 8888 with or without this field — that behavior is 100% controlled by the application's own code/config inside the image, completely independent of this YAML.

**Actually for:**
- Documentation — visible in `kubectl describe pod`, so you/tooling can see what port matters without reading the image's source
- Naming the port (`name: http`) so other objects can reference it by name instead of number (not used yet in this project, but the main real functional use)
- Required only if using `hostPort` (binding directly to the node's port — not used here)

Proof: a Service's `targetPort` works purely by matching the port the app *actually* listens on — zero dependency on whether `containerPort` was declared at all.

---

## 21. Part 3 — Exposing Services from K3d via Ingress

Port-forward (Section 13/17) is fine for quick debugging but temporary and blocks a terminal. The permanent fix is the same tool from Section 11 — Ingress — plus one extra step K3d needs that a VM (Part 1/2) didn't: **mapping the load balancer container's ports to your actual host** at cluster-creation time.

```bash
k3d cluster create mycluster -p "8080:80@loadbalancer" -p "8443:443@loadbalancer"
```

```
 -p "8080:80@loadbalancer"
      │      │    │
      │      │    └─ WHICH container: k3d's serverlb (= Traefik,
      │      │        same Ingress controller as Part 2)
      │      └─ container's port 80 (Traefik's HTTP listener)
      └─ YOUR host's port 8080
```

Before this flag, Traefik's port only existed *inside* Docker's private network — invisible to your host. A **404 Not Found** from `curl http://localhost:8080` after adding this flag is actually the correct, expected result at this stage: it proves the host→Docker→Traefik path works, Traefik is alive and responded — it just has no Ingress rules yet telling it where to route. Same situation as Part 2 before `ingress.yaml` existed, just now proven through a real network hop instead of assumed.

Watch the port numbers carefully: `-p "8080:80..."` maps HTTP only. `https://localhost:8080` will fail — either use `http://` on 8080, or add a second mapping (`8443:443`) for HTTPS, though Traefik needs an actual TLS cert configured to serve HTTPS meaningfully either way.

**Ingress for the app** (same shape as Part 2 exactly, just namespaced to `dev`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: playground-ingress
  namespace: dev
spec:
  rules:
    - host: playground.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wil-playground-svc
                port:
                  number: 8888
```

**Ingress for Argo CD itself** needs one extra patch first — Argo CD's server expects HTTPS by default and will redirect-loop behind a plain HTTP Ingress otherwise:
```bash
kubectl patch deployment argocd-server -n argocd --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/command/-", "value": "--insecure"}]'
```
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
spec:
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

**curl works immediately** (fake the Host header directly):
```bash
curl -H "Host: playground.local" http://localhost:8080
curl -k -H "Host: argocd.local" http://localhost:8080
```

**Browser needs one more step**, because a browser does a *real* DNS lookup for whatever hostname you type — there's no equivalent of curl's `-H` flag. Fake hostnames need to resolve to `127.0.0.1` via the hosts file. **On WSL2 specifically**, your browser runs on Windows, not inside WSL2 — so it's the **Windows** hosts file that needs editing, not the Linux one: `C:\Windows\System32\drivers\etc\hosts` (as Administrator):
```
127.0.0.1  playground.local
127.0.0.1  argocd.local
```
`127.0.0.1` works here because WSL2 automatically forwards `localhost` between Windows and WSL2 — the same reason `http://localhost:8080` already worked in-browser without any extra setup. Then browse directly to `http://playground.local:8080` / `http://argocd.local:8080`.

---

## 22. p3/ Folder Structure — What Goes Where

Rule of thumb: **`scripts/` = actions/commands that set things up. `confs/` = the actual declarative YAML objects you `kubectl apply`.**

```
p3/
├── scripts/
│   └── install.sh        ← installs Docker, k3d, kubectl; creates the
│                            cluster; installs Argo CD; applies confs/
└── confs/
    ├── namespaces.yaml    ← argocd + dev Namespace objects
    └── application.yaml   ← the Argo CD Application pointing at your
                              SEPARATE public GitOps repo
```

**Two different repos, easy to mix up:**
- **This p3/ folder** (in your 42 grading repo) — Vagrant-equivalent setup: the installer script + the two objects you apply by hand/script (namespaces, the Application pointer).
- **Your separate public GitHub repo** (e.g. `EzzineMehdi/argocd`) — contains ONLY the app's own `deployment.yaml`/`service.yaml`/`ingress.yaml`. This is what Argo CD *continuously watches* — it is not copied into the 42 repo at all, it's a standalone deliverable your `application.yaml`'s `repoURL` field points at.

`install.sh` applies the two `confs/` files by relative path (`"$(dirname "$0")/../confs/..."`) rather than duplicating their YAML inline — keeps the installer and the actual config cleanly separated, and matches how p1/p2 already split Vagrant provisioning scripts from the app manifests in `confs/`.

`bonus/` — skip entirely if not attempted; no empty folder needed.

---

## 23. Gotchas Actually Hit While Building This

1. **Duplicate private-network IP** — both VMs accidentally set to `.110` caused an unusable network; each node needs its own unique static IP.
2. **Stale provisioning** — editing a Vagrantfile's `provision` block does **nothing** to a VM that already exists. `vagrant up` only re-runs provisioners on first creation. Use `vagrant destroy -f && vagrant up` while iterating, or `vagrant reload --provision` to reapply without a full rebuild.
3. **Token mismatch** — worker joining with a hardcoded token while the server (rebuilt without that flag) generated a fresh random one → authentication silently retried forever instead of failing loud.
4. **Control-plane resource starvation** — 1 CPU/1GB is genuinely tight for K3s bootstrapping all its default system pods at once; can cause join requests to time out repeatedly even though the handshake is actually succeeding, just slowly. Confirmed by checking the *server's* logs for the actual certificate-signing line, not just the worker's timeout messages.
5. **NAT vs private network confusion** — `curl`/`ping` tests against `10.0.2.15` (NAT) prove nothing about node-to-node connectivity; only the `192.168.56.x` private-network IP matters for cluster communication.
6. **kubectl "hanging" on delete** — it's not stuck; `kubectl delete pod` blocks by default until the pod's graceful-shutdown grace period (default 30s) actually finishes. `--wait=false` returns immediately if you don't need to watch.
7. **vboxsf + nginx `sendfile` bug** — serving static files from a VirtualBox shared folder (`hostPath` → `/vagrant`) via nginx can truncate responses. ConfigMap-backed volumes avoid the host filesystem entirely and sidestep this.
8. **Renaming a Deployment isn't a rename** — changing `metadata.name` and reapplying creates a brand-new, separate object; the old one (and its pods) keeps running unless explicitly deleted, leading to accidental duplicates.
9. **DNS only works "for free" inside pods** — a node's own shell has a completely separate, Kubernetes-untouched `/etc/resolv.conf`; Service *names* only resolve automatically inside pods (or by explicitly pointing a query at coredns's ClusterIP manually).
10. **K3d on WSL2 + Docker Desktop: crash-restart loop** — server container shows `docker ps` as "Up," but the actual `k3s server` process inside was crash-looping (confirmed via `docker exec ... ps aux` showing no live k3s process, just the entrypoint + a `sleep 3` retry). Root cause traced to WSL2/Docker Desktop's networking+cgroup translation layer; this is a documented, recurring class of bug (e.g. k3d-io/k3d #773, #858), not a config mistake. Often resolves after a clean `k3d cluster delete` + recreate; if not, moving the whole workflow into a real Linux VM sidesteps it entirely (and satisfies the subject's "must be done in a VM" requirement more clearly than WSL2 does).
11. **Argo CD's CRDs are too big for normal `kubectl apply`** — `metadata.annotations: Too long: may not be more than 262144 bytes` on `applicationsets.argoproj.io`. Fixed with `--server-side --force-conflicts` (see Section 17).
12. **Private GitHub repo silently blocks Argo CD** — `SYNC STATUS: Unknown` with no obvious error until you `kubectl describe application ... -n argocd` and check `Conditions`. Repo must be public (also a hard subject requirement), and HTTPS `repoURL` (not SSH) avoids needing to configure a key at all for a public repo.
13. **`curl -H "Host: ..."` works, but a browser needs a real DNS entry** — a browser can't fake a Host header like curl can; a fake hostname needs a hosts-file entry to resolve to `127.0.0.1` before a browser will even attempt the request. On WSL2, this must go in the **Windows** hosts file, not the Linux one, since the browser runs on Windows.

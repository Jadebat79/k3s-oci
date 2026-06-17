# Two-Node k3s Staging Cluster on Oracle Cloud (Always Free)

A step-by-step guide to running a lightweight Kubernetes (k3s) cluster on OCI's
Always Free tier, with PostgreSQL for your staging apps.

> **Note on naming:** you mentioned "k6s" — that doesn't exist as a cluster.
> **k3s** is the lightweight Kubernetes distro you want. (k6 is an unrelated
> load-testing tool.)

---

## 0. Reality check: free-tier resources (June 2026)

On **June 15, 2026 Oracle halved the Always Free Ampere A1 allocation**:

| | Before (≤ Jun 14 2026) | Now (new tenancies) |
|---|---|---|
| Ampere A1 (ARM) | 4 OCPU / 24 GB | **2 OCPU / 12 GB total** |
| AMD micro (E2.1) | 2 × (1/8 OCPU, 1 GB) | unchanged |
| Block storage | 200 GB total | 200 GB total |

**What this means for you:**

- If you provisioned your existing servers **before June 15**, they're very
  likely **grandfathered** at the old 4 OCPU / 24 GB. Check first (Section 1) —
  if so, you have comfortable room for two nodes.
- If you're on the **new 2 OCPU / 12 GB** limit, a two-node cluster is still
  doable but tight. Recommended split:
  - **server (control-plane + worker):** 1 OCPU / 6 GB
  - **agent (worker):** 1 OCPU / 6 GB
- The AMD micro instances (1 GB RAM) are **too small** for k8s + Postgres —
  ignore them for cluster nodes. They're fine as a bastion/jump host if you want.

Use **ARM (Ampere A1)** instances with **Ubuntu 22.04** (examples below assume
Ubuntu; Oracle Linux 9 works too with `dnf` instead of `apt`).

---

## 1. Check what you already have

In the OCI Console:

1. **Compute → Instances** — note the shape (`VM.Standard.A1.Flex`), OCPU, and
   memory of each existing server. This tells you whether you're grandfathered.
2. **Governance → Limits, Quotas and Usage** — search for "Ampere" to see your
   current OCPU/memory ceiling.

Decide which instance is the **server** and which is the **agent**. Note the
**private IPs** of both (Console → instance → Primary VNIC → Private IP). You'll
use the private IP for node-to-node traffic — it's faster and free (no egress
charges).

> If you only have one instance, create a second `VM.Standard.A1.Flex` now, same
> region/AD, Ubuntu 22.04. If you hit "Out of host capacity," retry over a few
> hours or try a different Availability Domain — this is common on free tier.

---

## 2. Open the right ports (this trips up almost everyone)

OCI blocks traffic in **two** places. You must open ports in **both**.

### 2a. Cloud firewall (Security List or NSG)

Console → **Networking → Virtual Cloud Networks → your VCN → Security Lists →
Default Security List** → **Add Ingress Rules**. Add these (source =
**your VCN CIDR**, e.g. `10.0.0.0/16`, so it's internal-only):

| Port | Protocol | Purpose |
|---|---|---|
| 6443 | TCP | k3s API server |
| 8472 | UDP | Flannel VXLAN (node networking) |
| 10250 | TCP | kubelet metrics |
| 5432 | TCP | Postgres (intra-cluster, optional) |

For your own SSH/management, you likely already have 22/TCP open to your IP.
Only expose app ports (80/443) to `0.0.0.0/0` later, when you deploy an ingress.

### 2b. Host firewall (on each VM)

Ubuntu images on OCI ship with strict `iptables` rules. The simplest reliable
fix for a staging box is to flush the netfilter-persistent rules that block
inter-node traffic. On **both** nodes:

```bash
# Ubuntu: allow the k3s ports through iptables
sudo iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 8472 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
sudo netfilter-persistent save
```

> If you prefer, disabling `firewalld`/`ufw` entirely on a private-only staging
> box is acceptable, but the rules above are the minimal safe option.

---

## 3. Install the k3s server (control-plane) node

SSH into the **server** node. Replace `SERVER_PRIVATE_IP` with its actual
private IP.

```bash
export SERVER_PRIVATE_IP=10.0.0.10   # <-- your server's private IP

curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip=$SERVER_PRIVATE_IP \
  --advertise-address=$SERVER_PRIVATE_IP \
  --tls-san=$SERVER_PRIVATE_IP \
  --write-kubeconfig-mode=644 \
  --disable=traefik
```

Notes:
- `--disable=traefik` — we'll skip the bundled ingress for now (add NGINX
  ingress later if you need external HTTP). Drop this flag if you want Traefik.
- `--write-kubeconfig-mode=644` makes the kubeconfig readable without `sudo`.

Verify:

```bash
sudo k3s kubectl get nodes      # should show the server node Ready
```

Grab the **join token** (you'll need it for the agent):

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

> Guard this token — anyone with it has full cluster access.

---

## 4. Join the agent (worker) node

SSH into the **agent** node. Use the server's private IP and the token from
Section 3.

```bash
export SERVER_PRIVATE_IP=10.0.0.10              # server private IP
export NODE_TOKEN="K10abc...the-token-you-copied"
export AGENT_PRIVATE_IP=10.0.0.11               # this node's private IP

curl -sfL https://get.k3s.io | \
  K3S_URL=https://$SERVER_PRIVATE_IP:6443 \
  K3S_TOKEN=$NODE_TOKEN \
  sh -s - agent --node-ip=$AGENT_PRIVATE_IP
```

Back on the **server**, confirm both nodes are present:

```bash
sudo k3s kubectl get nodes -o wide
# NAME       STATUS   ROLES                  ...
# server     Ready    control-plane,master   ...
# agent      Ready    <none>                 ...
```

If the agent never reaches `Ready`, it's almost always the firewall (Section 2)
— check that UDP 8472 and TCP 6443 are open in **both** places.

---

## 5. Set up kubectl on your laptop (optional but recommended)

On the **server**:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy that to your laptop as `~/.kube/config`, then replace the `server:` line's
`127.0.0.1` with the server's **public IP** (and add 6443 to your cloud firewall
restricted to your home IP, plus `--tls-san=<public-ip>` at install time if you
didn't already).

For a private-only setup, just SSH into the server and use `k3s kubectl`.

---

## 6. PostgreSQL — recommendation and setup

### Where should it run? (you asked me to advise)

**Recommendation: run Postgres _inside_ the cluster as a StatefulSet, pinned to
one node, with automated `pg_dump` backups to OCI Object Storage.**

Why this over the alternatives:

- **Inside the cluster (recommended):** everything is declarative and lives with
  your app manifests; easy to recreate; one system to manage. The only real risk
  is losing the data volume on a node rebuild — which we neutralize with backups
  and by pinning the pod to a stable node.
- **On the host / separate VM:** more durable across cluster rebuilds, but you're
  now managing a database by hand outside k8s, and on a 12 GB free tier you can't
  really spare a whole VM for it. Better choice only once staging data becomes
  precious or you outgrow free tier. (Migration is easy later — point apps at an
  external `Service`/endpoint instead of the in-cluster one.)

### 6a. Namespace and credentials

```bash
kubectl create namespace data

kubectl -n data create secret generic pg-secret \
  --from-literal=POSTGRES_USER=staging \
  --from-literal=POSTGRES_PASSWORD='change-me-strong' \
  --from-literal=POSTGRES_DB=appdb
```

### 6b. Pin Postgres to the agent node

k3s ships the `local-path` storage provisioner, which creates a PersistentVolume
on **whatever node the pod lands on**. To keep the data volume stable, pin the
pod to one node. Label it first:

```bash
kubectl label node agent role=database
```

### 6c. Postgres StatefulSet + Service

Save as `postgres.yaml` and `kubectl apply -f postgres.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: data
spec:
  clusterIP: None          # headless service for the StatefulSet
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      nodeSelector:
        role: database       # pin to the labeled node
      containers:
        - name: postgres
          image: postgres:16
          envFrom:
            - secretRef:
                name: pg-secret
          ports:
            - containerPort: 5432
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "2Gi"
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
```

Verify and connect:

```bash
kubectl -n data get pods,pvc
kubectl -n data exec -it postgres-0 -- psql -U staging -d appdb -c '\l'
```

Apps in the cluster reach the DB at:
`postgres.data.svc.cluster.local:5432`

### 6d. Automated backups to OCI Object Storage (free tier)

OCI Always Free includes **20 GB of Object Storage** — perfect for dumps.

1. Create a bucket (Console → Storage → Buckets → "staging-pg-backups").
2. Create a **Pre-Authenticated Request (PAR)** for the bucket with write
   permission, or install the OCI CLI in the cron pod. Simplest is a PAR upload
   URL.
3. Run a daily `CronJob`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-backup
  namespace: data
spec:
  schedule: "0 2 * * *"        # 02:00 daily
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: postgres:16
              envFrom:
                - secretRef:
                    name: pg-secret
              env:
                - name: PAR_URL          # bucket PAR upload URL
                  value: "https://objectstorage.<region>.oraclecloud.com/p/<token>/n/<ns>/b/staging-pg-backups/o/"
              command:
                - /bin/sh
                - -c
                - >
                  pg_dump -h postgres -U "$POSTGRES_USER" "$POSTGRES_DB"
                  | gzip
                  | curl -s -T - "${PAR_URL}appdb-$(date +%F).sql.gz"
```

That gives you point-in-time dumps surviving any cluster rebuild. Restore is a
`gunzip | psql` away.

---

## 7. Deploy a staging app (example)

A minimal app + internal service that talks to Postgres:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: myapp }
  template:
    metadata:
      labels: { app: myapp }
    spec:
      containers:
        - name: myapp
          image: your-registry/myapp:staging
          env:
            - name: DATABASE_URL
              value: "postgres://staging:change-me-strong@postgres.data.svc.cluster.local:5432/appdb"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: default
spec:
  selector: { app: myapp }
  ports:
    - port: 80
      targetPort: 8080
```

To expose it on the internet, add an ingress controller (e.g. ingress-nginx via
Helm), open 80/443 in the cloud firewall and host iptables, and point a DNS
record at the server's public IP.

---

## 8. Handy day-to-day commands

```bash
# cluster health
kubectl get nodes
kubectl get pods -A

# logs / shell
kubectl -n data logs postgres-0
kubectl -n data exec -it postgres-0 -- bash

# restart k3s
sudo systemctl restart k3s          # server
sudo systemctl restart k3s-agent    # agent

# uninstall (clean slate)
/usr/local/bin/k3s-uninstall.sh         # server
/usr/local/bin/k3s-agent-uninstall.sh   # agent
```

---

## Quick reference: the whole flow

1. Confirm instance sizes; pick server + agent; note private IPs.
2. Open 6443/TCP, 8472/UDP, 10250/TCP in **both** the cloud Security List **and**
   host iptables.
3. Install k3s server with `--node-ip`/`--tls-san` set to its private IP.
4. Join the agent with `K3S_URL` + `K3S_TOKEN`.
5. Deploy Postgres as a pinned StatefulSet + nightly backup CronJob.
6. Deploy your apps pointing at `postgres.data.svc.cluster.local:5432`.

---

## Tradeoffs & when to revisit

- **2 OCPU / 12 GB is genuinely small.** If staging gets busy, either upgrade to
  a Pay As You Go account (the A1 free allowance still applies, you just pay for
  overflow), or move Postgres to a dedicated paid instance.
- **Single point of failure:** one server node = no HA control plane. For staging
  that's fine. HA needs 3 server nodes with embedded etcd — not feasible on free
  tier.
- **local-path storage is node-bound.** That's why we pin Postgres. For
  multi-node persistent storage, look at Longhorn later (it wants more RAM than
  free tier comfortably gives).

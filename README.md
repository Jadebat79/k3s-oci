# k3s on OCI Always Free — Terraform + Ansible

Provision a 3-node **k3s** cluster (1 server + 2 agents) on Oracle Cloud's
Always Free tier with **Terraform**, then configure it with **Ansible**:
host firewall, k3s, **ingress-nginx**, **cert-manager + Let's Encrypt TLS**, and
**PostgreSQL**. Built for staging workloads, with a **GitHub Actions** pipeline.

```
k3s-oci/
├── .github/workflows/
│   ├── ci.yml                 # fmt/validate/lint on every push & PR
│   └── deploy.yml             # manual: terraform apply/destroy + ansible
├── terraform/                 # OCI infrastructure
│   ├── versions.tf  variables.tf  network.tf  main.tf  outputs.tf
│   ├── templates/inventory.tpl
│   └── terraform.tfvars.example
├── ansible/                   # cluster config
│   ├── ansible.cfg  site.yml  group_vars/all.yml
│   └── roles/
│       ├── common/            # host firewall (iptables), packages
│       ├── k3s_server/        # install server, capture join token
│       ├── k3s_agent/         # join workers with the token
│       ├── helm/              # shared: install Helm
│       ├── ingress_nginx/     # ingress-nginx via Helm (LoadBalancer/klipper)
│       ├── cert_manager/      # cert-manager + LE staging/prod ClusterIssuers
│       └── postgres/          # StatefulSet + optional backup CronJob
└── examples/sample-app.yaml   # Deployment + Service + TLS Ingress
```

## How it fits together

1. **Terraform** creates the network and three `VM.Standard.A1.Flex` (ARM)
   instances, then writes the **Ansible inventory** with the real IPs.
2. **Ansible** opens host firewall ports → installs the k3s server and reads its
   join token → joins the agents → installs ingress-nginx and cert-manager →
   deploys Postgres.

The join token is never stored in Terraform — Ansible reads it off the server at
run time.

## Prerequisites

- Terraform ≥ 1.5, Ansible ≥ 2.15, an SSH keypair.
- OCI API credentials: **Console → Identity → Users → your user → API Keys → Add
  API Key**. Note the fingerprint, user OCID, tenancy OCID.

> **Check your quota first.** Console → **Governance → Limits, Quotas and Usage**
> → "Ampere". If it's **4 OCPU / 24 GB**, the defaults (3 nodes × 1 OCPU / 6 GB)
> work. If **2 OCPU / 12 GB**, set `agent_count = 1` (A1 needs a whole OCPU per
> node, so 3 nodes can't fit 2 OCPU).

## 1. Provision

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in OCIDs, key contents, sizing
terraform init && terraform apply
```

> "Out of host capacity" is common on free A1 — just re-run `terraform apply`.

## 2. Configure

Set your TLS values in `ansible/group_vars/all.yml` (`acme_email`, `app_domain`),
then:

```bash
cd ../ansible
ansible-playbook site.yml --extra-vars "pg_password=$(openssl rand -base64 24)"
```

## 3. Verify

```bash
ssh ubuntu@<server_public_ip>
kubectl get nodes                       # 1 control-plane + 2 workers, Ready
kubectl -n ingress-nginx get svc        # EXTERNAL-IP = node IP (via klipper)
kubectl get clusterissuers              # letsencrypt-staging / -prod, Ready
kubectl -n data get pods,pvc            # postgres-0 Running, PVC Bound
```

## 4. Deploy an app with HTTPS

1. Point DNS at the server's public IP — a real record, or `myapp.<IP>.sslip.io`.
2. Edit `examples/sample-app.yaml`: replace `YOUR_DOMAIN`, keep the issuer on
   `letsencrypt-staging` first.
3. `kubectl apply -f examples/sample-app.yaml`
4. Watch the cert: `kubectl describe certificate myapp-tls`. Once it issues with
   staging, switch the annotation to `letsencrypt-prod` and re-apply for a
   browser-trusted cert.

Apps reach the DB at `postgres.data.svc.cluster.local:5432`.

## Ingress & TLS notes

- **ingress-nginx** is exposed as a `LoadBalancer` service; k3s's built-in
  ServiceLB (klipper) binds it to the nodes' host ports 80/443 — no paid cloud
  load balancer needed.
- **cert-manager** uses an **HTTP-01** challenge, so the domain must resolve to
  the server and ports 80/443 must be open (Terraform `expose_http=true` + the
  host iptables rules handle this).
- Always validate with **letsencrypt-staging** first — production has strict
  rate limits and you can get blocked by repeated failures.

## GitHub Actions

- **ci.yml** runs `terraform fmt/validate` and `yamllint`/`ansible-lint` on every
  push and PR. No credentials needed.
- **deploy.yml** is **manual** (`workflow_dispatch`) and provisions real infra.
  Add these repo secrets: `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`,
  `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_PRIVATE_KEY`, `SSH_PUBLIC_KEY`,
  `SSH_PRIVATE_KEY`, `PG_PASSWORD`, `ACME_EMAIL`, `APP_DOMAIN`.

## Configuration reference

### Terraform (`terraform.tfvars`)

| Variable | Default | Notes |
|---|---|---|
| `agent_count` | `2` | Workers. Total = 1 + this. Set `1` on the 2-OCPU tier. |
| `instance_ocpus` | `1` | OCPUs per node (A1 min = 1). |
| `instance_memory_gbs` | `6` | RAM per node. |
| `expose_http` | `true` | Open 80/443 for ingress. |
| `ssh_allowed_cidr` | `0.0.0.0/0` | Lock to `YOUR_IP/32`. |
| `use_existing_vcn` | `false` | Set `true` to attach to an existing VCN. |
| `existing_vcn_ocid` | `""` | OCID of the existing VCN. |
| `vcn_compartment_ocid` | `""` | Compartment that owns the VCN (if different from `compartment_ocid`). |
| `existing_subnet_ocid` | `""` | Use an existing subnet; skips creating subnet/security list. |
| `existing_internet_gateway_id` | `""` | Required only when creating a new subnet in an existing VCN. |

### Using an existing VCN in another compartment

- Set `compartment_ocid` to where VMs should live (e.g. `k3-staging`).
- Set `use_existing_vcn = true`, `existing_vcn_ocid`, and `vcn_compartment_ocid`.
- **Bare VCN (no subnet/IGW yet):** leave `existing_subnet_ocid` and `existing_internet_gateway_id` empty. Terraform creates IGW, route table, security list, and a public subnet in the VCN compartment. Set `subnet_cidr` to a block inside the VCN CIDR.
- **Existing subnet:** set `existing_subnet_ocid` to attach VMs directly (ensure its security list allows k3s ports).
- **Existing IGW only:** set `existing_internet_gateway_id` if the VCN already has an IGW but no subnet yet.

Your OCI user/policy must allow compute in `compartment_ocid` and network manage in the VCN compartment.

### Ansible (`group_vars/all.yml`)

| Variable | Default | Notes |
|---|---|---|
| `k3s_version` | pinned | Bump from the k3s releases page. |
| `enable_ingress` / `enable_tls` | `true` | Toggle the add-ons. |
| `acme_email` | — | Let's Encrypt registration email. |
| `app_domain` | — | DNS name for your app (sslip.io works). |
| `cert_issuer` | `letsencrypt-staging` | Switch to `-prod` when ready. |
| `pg_password` | `change-me-strong` | **Override at run time.** |
| `pg_backup_par_url` | `""` | Set to an OCI Object Storage PAR URL for nightly backups. |

## Backups

In-cluster Postgres uses `local-path` storage (one node's disk), so the pod is
pinned. To survive a rebuild: create a bucket + **Pre-Authenticated Request**
(write) in OCI Object Storage, paste the PAR upload URL into `pg_backup_par_url`,
re-run the playbook. A daily CronJob does `pg_dump | gzip | upload`.

Restore: `gunzip < dump.sql.gz | kubectl -n data exec -i postgres-0 -- psql -U staging appdb`

## Teardown

```bash
cd terraform && terraform destroy
```

## Limitations

- **Single control-plane** — fine for staging, not HA (HA needs 3 server nodes).
- **Two firewalls** — Terraform handles the cloud Security List; Ansible's
  `common` role handles host iptables. Both required.
- The `node-token` grants full cluster admin; keep state/inventory private
  (already in `.gitignore`).

# gcp-postgres-terraform

> **Status:** In Progress - Phase 1 (Terraform Extraction)

Standalone PostgreSQL provisioning for GCP Compute Engine — extracted from [dev-nexus](https://github.com/patelmm79/dev-nexus).

**Why this exists:** PostgreSQL on Compute Engine with pgvector, not Cloud SQL — full control, free-tier eligible (e2-micro), and configurable via CLI, REST API, or MCP tools for AI agents.

---

## Features

- **PostgreSQL on GCP Compute Engine** (not Cloud SQL) with configurable version (14/15/16)
- **pgvector extension** for vector similarity search
- **Persistent data disk** that survives VM recreation
- **VPC isolation** with private subnet
- **Cloud NAT** for outbound internet access
- **VPC Access Connector** for Cloud Run integration
- **Automated backups** to GCS (daily cron)
- **Disk snapshots** for disaster recovery (daily at 2am UTC)
- **Cloud Monitoring** dashboards and alerts
- **Secret Manager** integration for credentials
- **Schema injection** at provisioning time

---

## Quick Start

### Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth application-default login`)
- Terraform 1.5+

### Install CLI (coming soon)

```bash
# Not yet built - see Phase 2
pip install gcp-postgres
```

### Provision via Terraform directly

```bash
cd terraform

# Copy and edit config
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Initialize
terraform init

# Preview
terraform plan

# Apply
terraform apply
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         GCP                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VPC (10.8.0.0/24)                      │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │  Subnet (10.8.0.0/24)                       │   │   │
│  │  │  ┌─────────────────────────────────────┐   │   │   │
│  │  │  │  PostgreSQL VM (e2-micro)           │   │   │   │
│  │  │  │  - Ubuntu 22.04                      │   │   │   │
│  │  │  │  - PostgreSQL 15 + pgvector          │   │   │   │
│  │  │  │  - Persistent Data Disk (pd-standard) │   │   │   │
│  │  │  └─────────────────────────────────────┘   │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │  ┌──────────────────┐  ┌──────────────────────┐   │   │
│  │  │  VPC Connector    │  │  Cloud NAT            │   │   │
│  │  │  (10.8.1.0/28)    │  │  (outbound internet)  │   │   │
│  │  └──────────────────┘  └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ Cloud Storage│  │ Secret Manager│  │ Cloud Monitor │   │
│  │ (backups)    │  │ (credentials) │  │ (dashboards)  │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
gcp-postgres-terraform/
├── terraform/
│   ├── versions.tf          # Terraform provider requirements
│   ├── variables.tf        # All configurable variables
│   ├── postgres_module.tf   # Core PostgreSQL provisioning
│   ├── outputs.tf          # Connection info, IPs, etc.
│   ├── terraform.tfvars.example
│   └── scripts/
│       ├── postgres_init.sh  # VM startup script
│       └── backup.sh         # Backup cron script
├── schema/
│   └── init.sql             # Base schema (pgvector + minimal)
├── cli/                     # Phase 2: CLI tools
├── api/                     # Phase 3: REST API
├── mcp/                     # Phase 4: MCP server
└── tests/                   # Phase 6: Tests
```

---

## Usage Examples

### Terraform (current)

```hcl
module "postgres" {
  source = "github.com/patelmm79/gcp-postgres-terraform//terraform"

  project_id         = "my-project"
  instance_name      = "my-db"
  postgres_db_name   = "mydb"
  postgres_db_user   = "mydb"
  postgres_db_password = var.my_db_password

  postgres_version = "15"
  machine_type     = "e2-micro"
  disk_size_gb     = 30

  pgvector_enabled = true
  init_sql          = file("schema.sql")
}
```

### CLI (Phase 2)

```bash
gcp-postgres create --name mydb --project my-project --region us-central1
gcp-postgres connect --name mydb
gcp-postgres backup --name mydb
gcp-postgres destroy --name mydb
```

### REST API (Phase 3)

```bash
curl -X POST https://api.example.com/v1/instances \
  -H "Content-Type: application/json" \
  -d '{"name": "mydb", "project": "my-project", "pgvector": true}'
```

### MCP Tools (Phase 4) - for AI agents

```
create_postgres_instance({name: "mydb", project: "my-project", pgvector: true})
destroy_postgres_instance({name: "mydb"})
get_instance_status({name: "mydb"})
trigger_backup({name: "mydb"})
```

---

## Connection Info (after terraform apply)

```bash
# Internal (from within VPC or Cloud Run)
psql -h <internal_ip> -U <user> -d <database>

# External (if assign_external_ip=true)
psql -h <external_ip> -U <user> -d <database>

# Get values from terraform output
terraform output internal_ip
terraform output connection_string_internal
terraform output psql_command_internal
```

---

## Cost (Free Tier Eligible)

| Resource | Configuration | Monthly Est. |
|----------|---------------|--------------|
| Compute Engine | e2-micro (us-central1) | ~$7/mo |
| Persistent Disk | 30GB pd-standard | ~$2/mo |
| Cloud NAT | ~1GB egress | ~$1/mo |
| Secret Manager | 5 secrets | ~$0.15/mo |
| Cloud Storage | 30GB backups | ~$1.50/mo |
| **Total** | | **~$12/mo** |

---

## Roadmap

| Phase | Status | Description |
|-------|--------|-------------|
| Phase 1 | **In Progress** | Extract & parameterize Terraform |
| Phase 2 | Not Started | CLI (`create`, `destroy`, `status`, `connect`, `backup`) |
| Phase 3 | Not Started | REST API (FastAPI) |
| Phase 4 | Not Started | MCP Server (AI agent tools) |
| Phase 5 | Not Started | Schema injection |
| Phase 6 | Not Started | Testing |

See [docs/superpowers/plans/2026-03-31-gcp-postgres-terraform-extraction-plan.md](docs/superpowers/plans/2026-03-31-gcp-postgres-terraform-extraction-plan.md) for full plan.

---

## Contributing

This is part of [dev-nexus](https://github.com/patelmm79/dev-nexus). Issues and PRs welcome.

---

## License

MIT

---

## Integration with Application Repos

This module is designed to be consumed as a **Git source module** by application repos. No code copying required — reference the module by tag, pin a version, and evolve independently.

### Module Source

```hcl
module "postgres" {
  source = "github.com/patelmm79/gcp-postgres-terraform//terraform?ref=v1.0"

  project_id             = "my-gcp-project"
  instance_name          = "my-db"
  postgres_db_name       = "my-db"
  postgres_db_user       = "my-db-user"
  postgres_db_password   = var.db_password   # from secrets manager or env

  # Optional: inject app-specific schema at provision time
  init_sql = file("${path.module}/../schemas/my-app-schema.sql")
}
```

> **Version pinning:** Use `?ref=v1.0` (or any git tag). Update by bumping the tag ref and running `terraform apply`. Never reference a branch (`main`) directly — branch history is mutable and can break your infrastructure silently.

### Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `project_id` | string | GCP project ID |
| `instance_name` | string | Unique name for all resources (lowercase, hyphens only) |
| `postgres_db_password` | string | Database password (store in Secret Manager, reference via `var`) |

### Optional Variables (commonly overridden)

| Variable | Default | Description |
|----------|---------|-------------|
| `postgres_db_name` | `"postgres"` | Database name |
| `postgres_db_user` | `"postgres"` | Database user |
| `postgres_version` | `"15"` | PostgreSQL version (14/15/16) |
| `machine_type` | `"e2-micro"` | VM machine type |
| `region` | `"us-central1"` | GCP region |
| `disk_size_gb` | `30` | Persistent disk size |
| `pgvector_enabled` | `true` | Enable pgvector extension |
| `init_sql` | `""` | SQL to run on DB init (schema injection) |
| `vpc_name` | `""` | Use existing VPC instead of creating new one |

### Terraform Outputs (for Application Integration)

After `terraform apply`, these outputs are used by the application:

| Output | Usage |
|--------|-------|
| `internal_ip` | `DB_HOST` environment variable for Cloud Run / Cloud Functions |
| `vpc_connector_name` | `VPC_CONNECTOR_NAME` — attach to Cloud Run for internal networking |
| `connection_string_internal` | Full connection URI for internal VPC access |
| `secrets` | Secret Manager IDs for `DB_PASSWORD`, `DB_USER`, `DB_HOST` |
| `backup_bucket_name` | GCS bucket for backup verification |

### Setting Up Terraform State (Required Before Use)

Terraform state must be stored in GCS to be shared across machines and to prevent state loss. Create the bucket first, then configure:

```bash
# Create the state bucket (one-time)
gsutil mb -l us-central1 gs://my-terraform-state-bucket

# Add backend config to your calling terraform config:
# terraform/backend.tf
terraform {
  backend "gcs" {
    bucket = "my-terraform-state-bucket"
    prefix = "postgres/state"
  }
}
```

Then run `terraform init` — it will prompt to migrate state if a local `.tfstate` exists.

### Schema Injection Pattern

To inject your application schema at provision time (recommended — no manual `psql` step):

```hcl
module "postgres" {
  source = "github.com/patelmm79/gcp-postgres-terraform//terraform?ref=v1.0"
  # ...
  init_sql = file("${path.module}/../schemas/app-schema.sql")
}
```

Your `schemas/app-schema.sql` should include:
- Table creation
- Row-Level Security (RLS) policies
- Index creation
- Any initial data

The SQL runs as the `postgres` superuser on first boot. Do not include `CREATE EXTENSION` statements for `vector` here — use `pgvector_enabled = true` instead (handled separately by the module).

### Schema Injection via Terraform Apply

If your schema changes after initial provisioning, run manually:

```bash
# Get the internal IP
INTERNAL_IP=$(terraform output -raw internal_ip)

# Apply schema update
psql -h $INTERNAL_IP -U postgres -d my-db -f schemas/app-schema.sql
```

Schema changes should be managed with a migration tool (e.g., `Flyway`, `Alembic`) in production — the `init_sql` variable only runs on first boot.

### Managing Module Updates

| Scenario | Action |
|---------|--------|
| Bug fix in module | `terraform apply` after `terraform get -u` |
| Pin to specific version | Change `?ref=v1.0` → `?ref=v1.1`, then `terraform apply` |
| GCP API breaking change | Pin to old version, update app repo separately |
| New region needed | Update `region` var, `terraform apply` |
| Postgres version upgrade | Update `postgres_version`, `terraform apply` (VM recreation required) |

### Tagging Releases

After any meaningful change to the module, tag a new version:

```bash
git tag -a v1.1 -m "Add disk usage alert threshold, update Ubuntu to 22.04"
git push origin v1.1
```

Use [Semantic Versioning](https://semver.org/):
- `v1.0` — initial stable release
- `v1.1` — backward-compatible additions (new outputs, new optional vars)
- `v2.0` — breaking changes (renamed vars, removed outputs, changed defaults)

### Migrating from Local State to GCS

If you already have local `.tfstate` files:

```bash
# 1. Add the GCS backend to your terraform block
terraform {
  backend "gcs" {
    bucket = "my-terraform-state-bucket"
    prefix = "postgres/state"
  }
}

# 2. Initialize — Terraform will prompt to migrate
terraform init

# 3. Confirm migration (type 'yes')
```

This is a one-time operation. After migration, delete local `.tfstate` files.

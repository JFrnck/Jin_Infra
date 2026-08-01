# Jin_Infra

Infraestructura de Jin: manifests Kustomize, scripts de bootstrap y scripts de backup. Flux reconcilia `k8s/overlays/production` contra el clúster K3s.

Documentación canónica en `../Jin_Docs/` (BLUEPRINT, AGENTS, WORKFLOW). Este README es el **runbook de bootstrap**: de una VM Ubuntu 24.04 limpia a clúster operativo en <2 h.

## Layout

```
k8s/
  base/
    namespaces/        jin, jin-executor, agents-sandbox (+quota/limits), observability
    network-policies/  aislamiento entre namespaces (BLUEPRINT 4.3)
    postgres/          Postgres 16 + pgvector, PVC 50Gi
    redis/             Redis 7 con AOF
    infisical/         gestor de secretos (usa el Postgres/Redis del clúster)
    cert-manager/      ClusterIssuer DNS-01 + Certificates wildcard (la app se instala en bootstrap)
    cloudflared/       túnel Cloudflare (modo token)
    traefik/           HelmChartConfig del Traefik bundled de K3s
    observability/     Prometheus + Loki + promtail + Grafana (mínimos; Tempo/PgBouncer pospuestos)
    backup/            PVC jin-core-data + 4 CronJobs (Postgres, Redis, memory.db, verify-restore)
  overlays/
    production/        entrypoint que Flux reconcilia
scripts/
  bootstrap/           pasos 01-06 del runbook
  backup/              scripts de backup (horneados en la imagen backup-tools)
docker/
  backup-tools/        imagen con pg_dump/redis-cli/sqlite3/age/rclone + los scripts de backup
```

Versiones de imágenes pinneadas en los manifests, verificadas contra Docker Hub/GitHub el 2026-07-20. Prohibido `latest`.

## Prerequisitos

- VM OCI Always Free ARM (4 vCPU / 24 GB / 200 GB), Ubuntu 24.04, acceso SSH.
- Dominios `jeanfranck.com` y `jinserver.com` con DNS en Cloudflare.
- Cuenta Cloudflare con Zero Trust habilitado (plan free basta).
- En tu máquina o la VM: `git`, `curl`, `dig`.
- Llavero (Bitwarden/1Password) listo para guardar las credenciales que generes.

## Runbook de bootstrap

Todos los scripts se corren **en la VM**, desde la raíz de este repo clonado. Son idempotentes: re-ejecutar es seguro.

### 1. K3s (~10 min)

```bash
./scripts/bootstrap/01-install-k3s.sh
```

Instala K3s pinneado (`K3S_VERSION` para cambiarlo) con `servicelb` deshabilitado: la única entrada al clúster es el túnel — la IP pública de OCI no escucha en 80/443. Deja `kubectl` configurado para tu usuario.

### 2. Túnel y tokens en Cloudflare (~20 min, manual)

En el dashboard de Cloudflare:

1. **Zero Trust → Networks → Tunnels → Create tunnel** (tipo Cloudflared), nombre `jin`. Copia el **token del túnel** (lo pide el paso 3).
2. En el túnel, **Public Hostnames** — crea dos entradas:
   - `*.jeanfranck.com` → Service `https://traefik.kube-system.svc.cluster.local:443`, TLS → Origin Server Name: `*.jeanfranck.com`.
   - `*.jinserver.com` → Service `https://traefik.kube-system.svc.cluster.local:443`, TLS → Origin Server Name: `*.jinserver.com`.
3. **DNS de cada zona**: si el wizard no los creó, añade CNAME `*` → `<tunnel-id>.cfargotunnel.com` (proxied) en `jeanfranck.com` y en `jinserver.com`.
4. **API token** (My Profile → API Tokens): permisos `Zone.DNS: Edit` **solo** sobre las dos zonas. Es para el DNS-01 de cert-manager.

### 3. Secrets semilla (~15 min)

Infisical corre dentro del clúster, así que estos secretos iniciales se siembran a mano — es la única excepción a "todo en Infisical". Genera y exporta (y guarda en tu llavero):

```bash
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export INFISICAL_ENCRYPTION_KEY="$(openssl rand -hex 16)"
export INFISICAL_AUTH_SECRET="$(openssl rand -base64 32)"
export CLOUDFLARE_API_TOKEN="<token del paso 2.4>"
export CLOUDFLARED_TUNNEL_TOKEN="<token del paso 2.1>"
export GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# Para los backups cifrados (Fase 1.2, ver sección "Backups" más abajo):
age-keygen -o /tmp/jin-backup-key.txt
export AGE_PUBLIC_KEY="$(grep '# public key:' /tmp/jin-backup-key.txt | cut -d: -f2 | tr -d ' ')"
export AGE_PRIVATE_KEY="$(grep AGE-SECRET-KEY /tmp/jin-backup-key.txt)"
# Guarda /tmp/jin-backup-key.txt en tu llavero YA MISMO y luego bórralo:
#   shred -u /tmp/jin-backup-key.txt
# Sin esa llave privada, ningún backup es recuperable — es la única copia
# fuera del clúster (el clúster solo tiene ambas mitades en el Secret).

export R2_ACCOUNT_ID="<Cloudflare dashboard → R2 → cuenta>"
export R2_ACCESS_KEY_ID="<R2 → Manage API tokens → crear token scoped al bucket jin-backups>"
export R2_SECRET_ACCESS_KEY="<secret del token anterior>"

./scripts/bootstrap/02-seed-secrets.sh
```

### 4. Aplicar manifests (~20 min)

```bash
./scripts/bootstrap/04-apply-manifests.sh
```

Instala cert-manager pinneado, hace `kubectl apply --dry-run=server` de todo el overlay (falla temprano si algo está mal), aplica, y espera cada rollout. Los certificados wildcard tardan ~2 min en emitirse (DNS-01).

### 5. Verificación del túnel y DNS

```bash
./scripts/bootstrap/03-verify-tunnel-dns.sh
kubectl get certificate -A          # READY=True en los tres
curl -sI https://grafana.jeanfranck.com # 200/302 (o pantalla de Cloudflare Access si ya está el paso 7)
```

### 6. GitOps con Flux (~10 min)

```bash
export GITHUB_TOKEN="<PAT con scope repo>"
./scripts/bootstrap/05-flux-bootstrap.sh
```

A partir de aquí, `git push` a `main` ⇒ Flux aplica en ≤5 min. Los cambios de infra ya no se aplican a mano.

### 7. Cloudflare Access (~10 min, manual)

Zero Trust → Access → Applications: crea una aplicación self-hosted para `grafana.jeanfranck.com` (y futuras: `dash.jeanfranck.com`, `app-*.jinserver.com`) con política de allow solo para tu email. Obligatorio según BLUEPRINT 5.1/5.4.

### 8. Pre-pull de la imagen Deno

```bash
./scripts/bootstrap/06-prepull-deno.sh
```

No hay warm pool: los pods de agentes se crean bajo demanda y la imagen cacheada da arranques de ~2-5 s. Re-ejecutar tras cada upgrade de imagen.

### 9. `fs.inotify.max_user_watches` (Fase 5.5, ADR 0006)

```bash
./scripts/bootstrap/07-sysctl-inotify.sh
```

Sin esto, el hot reload de los pods de servicio (`npm run dev`, etc. bajo `*.jinserver.com`) deja de funcionar **en silencio** al agotarse el límite default del kernel — no es un sysctl seteable por pod (no está namespaced), así que se sube una vez en el nodo. Persistente vía `/etc/sysctl.d/99-jin-inotify.conf`, sobrevive reboots.

## Backups (Fase 1.2)

Cron diario (BLUEPRINT 3.5), streaming puro — el dump nunca toca disco sin cifrar:

- **03:00** `backup-postgres` — `pg_dump --format=custom` contra `postgres.jin.svc` → age → R2 (`postgres/YYYY-MM-DD.age`).
- **03:10** `backup-redis` — `redis-cli --rdb -` (protocolo, sin montar el PVC de Redis) → age → R2.
- **03:20** `backup-memory` — `sqlite3 memory.db ".backup"` desde la PVC `jin-core-data` (solo-lectura). **Antes de la Fase 4** (cuando exista `src/memory/` en Jin_Core) el archivo no existe todavía: el CronJob lo detecta y sale OK sin subir nada — no es un fallo, es orden temporal esperado.
- **Día 1, 04:00** `verify-restore` — descarga el dump de Postgres más reciente, lo descifra (única pieza que usa la llave privada de age, montada como archivo, nunca como env var), levanta un Postgres efímero *dentro del mismo pod* (`initdb`/`pg_ctl`, sin tocar el Postgres real), restaura y valida. Notifica por Telegram (**stub** — la integración real llega en la Fase 2.4).

**Retención:** 7 diarios + 4 semanales (domingo) + 3 mensuales (día 1), implementada en `scripts/backup/lib/common.sh::enforce_retention` y corrida tras cada upload exitoso.

**Imagen:** ninguna imagen oficial trae `pg_dump` + `redis-cli` + `sqlite3` + `age` + `rclone` juntos, así que este repo construye la suya — `docker/backup-tools/` (Alpine 3.20, paquetes pinneados, build context = raíz del repo porque hornea `scripts/backup/` dentro de la imagen). CI propio en `.github/workflows/backup-tools.yaml`, publica en `ghcr.io/jfrnck/jin-backup-tools:v1`. **Antes de que los CronJobs puedan correr, esa imagen debe existir en GHCR** — el primer push a `main` que toque `docker/backup-tools/**` la construye.

**Volumen compartido:** `jin-core-data` (PVC, namespace `jin`) se declara en `k8s/base/backup/core-data-pvc.yaml` *antes* de que exista el Deployment de Jin_Core. Cuando ese Deployment se cree (Fase 2/4), debe montar el mismo PVC en `/data/memory` — es el contrato entre este repo y el módulo `src/memory/` de Jin_Core.

**Tests:** `scripts/backup/test/*.bats` (cifrado age con detección de tampering, retención 7/4/3) corren en CI contra un `mock-rclone` que simula R2 como directorio local — no requieren credenciales reales. `bats scripts/backup/test/*.bats` para correrlos en local (requiere `age` instalado).

## Criterio de éxito de la Fase 1

- `https://grafana.jeanfranck.com` responde con TLS válido (wildcard de Let's Encrypt) detrás de Cloudflare Access, y su dashboard muestra métricas de K3s (datasource Prometheus).
- `kubectl get certificate -A` muestra los tres certificados `READY=True`.
- `kubectl get pods -A` sin CrashLoopBackOff.
- Backups cifrados subiendo a R2 (Fase 1.2) — verificable con `kubectl -n jin get cronjob` y, tras la primera ejecución, `rclone lsf` contra el bucket.

## Notas de diseño

- **Secrets:** ningún YAML de este repo contiene un secreto; todos referencian Secrets de K8s sembrados por `02-seed-secrets.sh` (semilla) o gestionados vía Infisical después. `gitleaks` corre en pre-commit en los repos de app.
- **agents-sandbox:** ResourceQuota como techo de ráfaga (6Gi/1500m, consumo idle cero), LimitRange con default 512Mi/500m y máximo 2Gi/1500m, PSA `restricted`, y NetworkPolicy default-deny con solo DNS de salida — las whitelists por tool las inyecta el Executor en runtime (Fase 5).
- **1 réplica + `maxSurge: 1, maxUnavailable: 0`** en los Deployments con rolling update: cero downtime sin pods redundantes (ANALISIS §7).
- **Infisical UI:** solo interna. `kubectl -n jin port-forward svc/infisical 8080:8080` → `http://localhost:8080`. No se expone por el túnel.
- **Postgres/Redis compartidos con Infisical:** el init de Postgres crea la DB `infisical`; Redis se comparte con password. A este presupuesto de RAM no hay sitio para instancias dedicadas.

## Operación

- Cambios de infra: PR a `main` de este repo → CI (kube-linter + shellcheck + bats) → merge humano → Flux aplica.
- Cambios a `docker/backup-tools/Dockerfile` o `scripts/backup/`: bump del tag en `IMAGE_TAG` (backup-tools.yaml) y en los 4 CronJobs, mismo PR.
- Runbooks operativos (restore, VM perdida, rotación de tokens): `../Jin_Docs/docs/runbooks/`.

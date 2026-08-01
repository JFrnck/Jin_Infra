# backup-tools

Imagen mínima (Alpine 3.20) con `pg_dump`/`pg_restore`/`psql`/`initdb`/`pg_ctl`, `redis-cli`, `sqlite3`, `age` y `rclone` — las herramientas que usan los scripts de `../../scripts/backup/`, que además vienen horneados en `/scripts` dentro de la imagen. Ninguna imagen oficial trae las cinco juntas.

Publicada en `ghcr.io/jfrnck/jin-backup-tools`, pinneada con un tag de versión manual (nunca `latest`).

**Build context = raíz del repo**, no este directorio (necesita `COPY scripts/backup /scripts`):

```bash
docker build -f docker/backup-tools/Dockerfile -t jin-backup-tools:local ../..
```

## Cuándo bumpear la versión

Cada vez que cambies este `Dockerfile` (nuevo paquete, versión de Alpine, etc.):

1. Sube el número de tag en `.github/workflows/backup-tools.yaml` (`IMAGE_TAG`).
2. Actualiza la misma referencia en los 4 `k8s/base/backup/cronjob-*.yaml`.
3. Un solo PR con ambos cambios — el drift entre el tag construido y el referenciado en los manifests es exactamente lo que este paso evita.

## CI

`.github/workflows/backup-tools.yaml` construye y publica la imagen en cada push a `main` que toque `docker/backup-tools/**`.

# Chaos tests

3 scripts que verifican el criterio de BLUEPRINT §13.2 ("chaos test mensual") y §7 ("7 días autónomo sin intervención salvo aprobaciones HITL") — hallazgo de la auditoría de seguridad Fase 7.3 (ver `Jin_Docs/docs/security-audit-fase7.md`): no existían.

**Limitación real, no resuelta por código:** los 3 requieren un clúster real corriendo con `jin-core`/`executor`/Postgres desplegados — no hay uno hoy (el deploy real está pospuesto hasta el final del roadmap, decisión del owner 2026-08-07). Estos scripts están completos, con `shellcheck` limpio y listos, pero **ninguno se ejecutó todavía contra un clúster real**. Corrélos como parte de la Fase 7.2 (activación) o del runbook de verificación mensual una vez que el sistema esté vivo.

## 01-kill-core-mid-dual-confirm.sh

Mata el pod de `jin-core` con una aprobación `confirm`/`dual-confirm` a medias. Verifica que el estado sobrevive — vive en Postgres (`pending_approvals`), no en memoria del proceso — y que el pod recupera `Ready` rápido (BLUEPRINT 13.2: recovery <10s).

**Precondición manual:** disparar una acción `confirm`/`dual-confirm` real antes de correr el script (ej. pedirle al agente por Telegram que mande un correo), para que exista al menos una aprobación pendiente.

```bash
export JIN_API_URL=https://jin.jeanfranck.com/api JIN_JWT=...
bash 01-kill-core-mid-dual-confirm.sh
```

## 02-kill-postgres.sh

Tira el pod de Postgres. Verifica que `jin-core` falla ruidoso (`/health/ready` cae a NotReady, nunca sigue operando a medias sin DB — AGENTS.md 1.4) y hace un spot-check del hash chain del audit log antes/después para confirmar que el crash no lo corrompió.

**Limitación documentada en el propio script:** el spot-check es de las últimas 5 filas, no la verificación completa (`ChainVerificationService`, `@Cron` nocturno a las 4am UTC, sin endpoint HTTP para dispararla a demanda). Complementario, no un sustituto.

```bash
export JIN_API_URL=https://jin.jeanfranck.com/api POSTGRES_PASSWORD=...
bash 02-kill-postgres.sh
```

## 03-simulate-runaway.sh

Inserta directo en `budget_hourly_usage` 24h de consumo bajo + 1 hora de consumo disparado (evita quemar tokens reales), espera hasta ~6 minutos a que `KillSwitchService` (corre cada 5 min) lo detecte, y verifica `killSwitchActive: true` vía `GET /api/budget`. Al final hace `/api/budget/unpause` y borra las filas simuladas.

**Verificación manual, no automatizable:** confirmar que la alerta llegó al chat de Telegram del owner.

```bash
export JIN_API_URL=https://jin.jeanfranck.com/api JIN_JWT=... POSTGRES_PASSWORD=...
bash 03-simulate-runaway.sh
```

## Qué esperar de cada uno

| Script | Éxito | Si falla |
| --- | --- | --- |
| 01 | La misma aprobación sigue pendiente, `jin-core` vuelve a `Ready` en segundos | El estado dependía de memoria del proceso, o el pod tarda demasiado en recuperar |
| 02 | `jin-core` reporta `NotReady` mientras Postgres está caído, y el audit log queda intacto al volver | `jin-core` operó sin DB (grave), o el hash chain se corrompió |
| 03 | El kill switch se activa dentro de ~6 minutos | El runaway no se detecta, o tarda más de lo esperado |

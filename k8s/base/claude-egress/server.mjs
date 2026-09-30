// Proxy de salida de Claude Code (ADR 0017). Los pods de terminal que el owner
// abre con "Habilitar Claude Code" salen SOLO por acá, y acá solo se puede llegar
// a los servidores de Anthropic. Es un túnel TCP (HTTP CONNECT): NO descifra el
// tráfico, no ve el token ni la conversación, y no guarda nada más que host,
// bytes y duración.
//
// Sin dependencias: solo módulos de Node. Corre como `node /app/server.mjs`
// desde un ConfigMap (patrón del proxy de npm) y se prueba con `node --test`.
import dns from 'node:dns/promises';
import http from 'node:http';
import net from 'node:net';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const TARGET = /^([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+):(\d{1,5})$/i;

/**
 * ¿Es una dirección que un proxy expuesto a código no confiable NUNCA debe
 * alcanzar? Privadas, loopback, link-local (incluye el endpoint de metadatos
 * 169.254.169.254), CGNAT, multicast y reservadas — también en IPv6 y como
 * IPv4 mapeada en IPv6. Defensa contra SSRF si un dominio permitido resolviera
 * a algo interno.
 */
export function isBlockedAddress(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 192 && b === 0) ||
      (a === 198 && (b === 18 || b === 19)) ||
      a >= 224
    );
  }
  if (net.isIPv6(address)) {
    const lower = address.toLowerCase();
    const mapped = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return isBlockedAddress(mapped[1]);
    if (lower === '::' || lower === '::1') return true;
    const first = parseInt(lower.split(':')[0] || '0', 16);
    return (
      (first & 0xfe00) === 0xfc00 || // fc00::/7 (únicas locales)
      (first & 0xffc0) === 0xfe80 || // fe80::/10 (link-local)
      (first & 0xff00) === 0xff00 //    ff00::/8 (multicast)
    );
  }
  return true; // no es una IP: se trata como bloqueada
}

/**
 * @param {object} options
 * @param {Set<string>} options.allowedHosts dominios exactos permitidos (en minúsculas)
 * @param {number} [options.maxTunnels]
 * @param {number} [options.maxLifetimeMs]
 * @param {number} [options.idleTimeoutMs]
 * @param {(host: string) => Promise<{address: string}[]>} [options.lookup]
 * @param {(port: number, host: string) => net.Socket} [options.connect]
 * @param {(line: object) => void} [options.log]
 */
export function createProxy(options) {
  const {
    allowedHosts,
    maxTunnels = 20,
    maxLifetimeMs = 60 * 60 * 1000,
    idleTimeoutMs = 10 * 60 * 1000,
    lookup = (host) => dns.lookup(host, { all: true }),
    connect = (port, host) => net.connect(port, host),
    log = (line) => console.log(JSON.stringify(line)),
  } = options;

  let active = 0;
  const server = http.createServer((_req, res) => {
    res.writeHead(405, { Allow: 'CONNECT', 'Content-Type': 'text/plain' });
    res.end('Solo se acepta CONNECT.\n');
  });

  const refuse = (socket, status, reason, host) => {
    log({ event: 'refused', status, reason, host });
    socket.end(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\n\r\n`);
  };

  server.on('connect', async (req, clientSocket, head) => {
    clientSocket.on('error', () => {});
    const match = TARGET.exec(req.url ?? '');
    if (!match) return refuse(clientSocket, 400, 'Bad Request', 'invalid');
    const host = match[1].toLowerCase();
    const port = Number(match[5]);
    // Una IP literal nunca es un dominio permitido: se rechaza explícito.
    if (/^[\d.]+$/.test(host)) return refuse(clientSocket, 400, 'Bad Request', host);
    if (port !== 443 || !allowedHosts.has(host)) {
      return refuse(clientSocket, 403, 'Forbidden', host);
    }
    if (active >= maxTunnels) {
      return refuse(clientSocket, 503, 'Service Unavailable', host);
    }
    active += 1;
    let released = false;
    const release = () => {
      if (!released) {
        released = true;
        active -= 1;
      }
    };

    let address;
    try {
      const addresses = await lookup(host);
      // TODAS las direcciones tienen que ser públicas, y se conecta a la IP
      // ya verificada (no al nombre): sin ventana para un rebinding de DNS.
      if (addresses.length === 0 || addresses.some((a) => isBlockedAddress(a.address))) {
        release();
        return refuse(clientSocket, 403, 'Forbidden', host);
      }
      address = addresses[0].address;
    } catch {
      release();
      return refuse(clientSocket, 502, 'Bad Gateway', host);
    }

    const startedAt = Date.now();
    let up = 0;
    let down = 0;
    const upstream = connect(port, address);
    upstream.on('error', () => {});

    const close = () => {
      clientSocket.destroy();
      upstream.destroy();
    };
    upstream.once('connect', () => {
      clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length > 0) upstream.write(head);
      clientSocket.on('data', (chunk) => {
        up += chunk.length;
      });
      upstream.on('data', (chunk) => {
        down += chunk.length;
      });
      clientSocket.pipe(upstream);
      upstream.pipe(clientSocket);
    });
    const lifetime = setTimeout(close, maxLifetimeMs);
    clientSocket.setTimeout(idleTimeoutMs, close);
    upstream.setTimeout(idleTimeoutMs, close);
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(lifetime);
      release();
      log({ event: 'closed', host, bytesUp: up, bytesDown: down, ms: Date.now() - startedAt });
      close();
    };
    clientSocket.once('close', finish);
    upstream.once('close', finish);
  });

  return server;
}

// Arranque: solo si se ejecuta directamente (no al importarlo desde las pruebas).
// Se compara la ruta REAL: un ConfigMap monta el archivo como enlace simbólico
// (/app/server.mjs -> ..data/server.mjs), y `import.meta.url` ya viene resuelto;
// comparar contra `argv[1]` tal cual hacía que el proceso terminara sin escuchar
// (CrashLoopBackOff con código 0 en el primer despliegue, 2026-09-30).
function isMain() {
  try {
    return (
      Boolean(process.argv[1]) &&
      realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
    );
  } catch {
    return false;
  }
}

if (isMain()) {
  const allowedHosts = new Set(
    (process.env.ALLOWED_HOSTS ?? 'api.anthropic.com')
      .split(',')
      .map((host) => host.trim().toLowerCase())
      .filter(Boolean),
  );
  const server = createProxy({
    allowedHosts,
    maxTunnels: Number(process.env.MAX_TUNNELS ?? 20),
    maxLifetimeMs: Number(process.env.MAX_LIFETIME_SECONDS ?? 3600) * 1000,
    idleTimeoutMs: Number(process.env.IDLE_TIMEOUT_SECONDS ?? 600) * 1000,
  });
  const port = Number(process.env.PORT ?? 3128);
  server.listen(port, '0.0.0.0', () => {
    console.log(JSON.stringify({ event: 'listening', port, allowedHosts: [...allowedHosts] }));
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0));
}

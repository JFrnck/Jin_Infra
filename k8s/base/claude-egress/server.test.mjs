import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';
import { after, describe, it } from 'node:test';
import { createProxy, isBlockedAddress } from './server.mjs';

const PUBLIC = [{ address: '160.79.104.10' }];

/** "Upstream" local: repite lo que recibe con un prefijo. */
async function echoServer() {
  const server = net.createServer((socket) => {
    socket.on('data', (data) => socket.write(`eco:${data}`));
    socket.on('error', () => {});
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return server;
}

async function startProxy(overrides = {}) {
  const echo = await echoServer();
  const connects = [];
  const proxy = createProxy({
    allowedHosts: new Set(['api.anthropic.com', 'claude.ai']),
    lookup: async () => PUBLIC,
    // El "internet" de las pruebas: todo lo permitido termina en el eco local.
    connect: (port, host) => {
      connects.push({ port, host });
      return net.connect(echo.address().port, '127.0.0.1');
    },
    log: () => {},
    ...overrides,
  });
  const sockets = new Set();
  proxy.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  const echoSockets = new Set();
  echo.on('connection', (socket) => {
    echoSockets.add(socket);
    socket.on('close', () => echoSockets.delete(socket));
  });
  await new Promise((resolve) => proxy.listen(0, '127.0.0.1', resolve));
  return {
    proxy,
    connects,
    port: proxy.address().port,
    async stop() {
      for (const socket of [...sockets, ...echoSockets]) socket.destroy();
      await new Promise((resolve) => proxy.close(resolve));
      await new Promise((resolve) => echo.close(resolve));
    },
  };
}

/** Manda un CONNECT crudo y devuelve la primera línea de la respuesta y el socket. */
function connectVia(port, target) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    let buffer = '';
    socket.on('error', reject);
    socket.on('data', function onData(chunk) {
      buffer += chunk.toString();
      if (buffer.includes('\r\n\r\n')) {
        socket.off('data', onData);
        resolve({ status: buffer.split('\r\n')[0], socket, rest: buffer.split('\r\n\r\n')[1] ?? '' });
      }
    });
    socket.on('close', () => resolve({ status: buffer.split('\r\n')[0] || 'cerrado', socket, rest: '' }));
    // Una respuesta que no es 200 no abre túnel: el cliente cierra por su lado.
    socket.setTimeout(3000, () => socket.destroy());
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);
  });
}

describe('isBlockedAddress', () => {
  const blocked = [
    '10.0.0.5', '10.42.1.1', '127.0.0.1', '0.0.0.0', '169.254.169.254', '172.16.0.1', '172.31.255.255',
    '192.168.1.1', '100.64.0.1', '224.0.0.1', '255.255.255.255', '::1', '::', 'fc00::1', 'fd12:3456::1',
    'fe80::1', 'ff02::1', '::ffff:10.0.0.1', '::ffff:127.0.0.1', 'no-es-una-ip',
  ];
  const allowed = ['160.79.104.10', '8.8.8.8', '172.15.0.1', '172.32.0.1', '2607:6bc0::10', '::ffff:8.8.8.8'];

  for (const address of blocked) it(`bloquea ${address}`, () => assert.equal(isBlockedAddress(address), true));
  for (const address of allowed) it(`permite ${address}`, () => assert.equal(isBlockedAddress(address), false));
});

describe('proxy CONNECT', () => {
  it('un dominio permitido abre el túnel y los datos van y vuelven; conecta a la IP verificada, no al nombre', async () => {
    const ctx = await startProxy();
    const { status, socket } = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(status, /^HTTP\/1\.1 200/);
    assert.deepEqual(ctx.connects, [{ port: 443, host: '160.79.104.10' }]);

    const reply = await new Promise((resolve) => {
      socket.once('data', (data) => resolve(data.toString()));
      socket.write('hola');
    });
    assert.equal(reply, 'eco:hola');
    socket.destroy();
    await ctx.stop();
  });

  it('el dominio se compara en minúsculas y exacto (un subdominio o sufijo ajeno no pasa)', async () => {
    const ctx = await startProxy();
    for (const target of ['API.Anthropic.com:443']) {
      const { status, socket } = await connectVia(ctx.port, target);
      assert.match(status, /^HTTP\/1\.1 200/);
      socket.destroy();
    }
    for (const target of [
      'evil.api.anthropic.com:443',
      'api.anthropic.com.evil.com:443',
      'notapi.anthropic.com:443',
      'anthropic.com:443',
    ]) {
      const { status } = await connectVia(ctx.port, target);
      assert.match(status, /^HTTP\/1\.1 403/, target);
    }
    await ctx.stop();
  });

  it('un dominio que no está en la lista se rechaza con 403 y NO se conecta a nada', async () => {
    const ctx = await startProxy();
    const { status } = await connectVia(ctx.port, 'example.com:443');
    assert.match(status, /^HTTP\/1\.1 403/);
    assert.deepEqual(ctx.connects, []);
    await ctx.stop();
  });

  it('solo el puerto 443', async () => {
    const ctx = await startProxy();
    for (const target of ['api.anthropic.com:80', 'api.anthropic.com:22', 'api.anthropic.com:8443']) {
      const { status } = await connectVia(ctx.port, target);
      assert.match(status, /^HTTP\/1\.1 403/, target);
    }
    assert.deepEqual(ctx.connects, []);
    await ctx.stop();
  });

  it('destinos mal formados o IP literales se rechazan (400)', async () => {
    const ctx = await startProxy();
    for (const target of ['1.2.3.4:443', '[::1]:443', 'localhost:443', 'a@api.anthropic.com:443', 'api.anthropic.com', 'api.anthropic.com:443/x']) {
      const { status } = await connectVia(ctx.port, target);
      assert.match(status, /^HTTP\/1\.1 400/, target);
    }
    assert.deepEqual(ctx.connects, []);
    await ctx.stop();
  });

  it('si el dominio permitido resolviera a una IP interna, se rechaza (SSRF) y no se conecta', async () => {
    for (const address of ['10.43.0.10', '127.0.0.1', '169.254.169.254', '::1', 'fd00::5']) {
      const ctx = await startProxy({ lookup: async () => [{ address }] });
      const { status } = await connectVia(ctx.port, 'api.anthropic.com:443');
      assert.match(status, /^HTTP\/1\.1 403/, address);
      assert.deepEqual(ctx.connects, [], address);
      await ctx.stop();
    }
  });

  it('basta UNA dirección interna entre varias para rechazar', async () => {
    const ctx = await startProxy({ lookup: async () => [{ address: '160.79.104.10' }, { address: '10.0.0.9' }] });
    const { status } = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(status, /^HTTP\/1\.1 403/);
    await ctx.stop();
  });

  it('un fallo de DNS da 502, sin colgarse', async () => {
    const ctx = await startProxy({ lookup: async () => { throw new Error('ENOTFOUND'); } });
    const { status } = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(status, /^HTTP\/1\.1 502/);
    await ctx.stop();
  });

  it('un pedido HTTP normal (no CONNECT) se rechaza con 405', async () => {
    const ctx = await startProxy();
    const status = await new Promise((resolve, reject) => {
      const socket = net.connect(ctx.port, '127.0.0.1', () => {
        socket.write('GET http://api.anthropic.com/ HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n');
      });
      socket.once('data', (data) => { resolve(data.toString().split('\r\n')[0]); socket.destroy(); });
      socket.on('error', reject);
    });
    assert.match(status, /^HTTP\/1\.1 405/);
    assert.deepEqual(ctx.connects, []);
    await ctx.stop();
  });

  it('respeta el tope de túneles simultáneos (503) y lo libera al cerrar', async () => {
    const ctx = await startProxy({ maxTunnels: 1 });
    const first = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(first.status, /^HTTP\/1\.1 200/);

    const second = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(second.status, /^HTTP\/1\.1 503/);

    first.socket.destroy();
    await new Promise((resolve) => setTimeout(resolve, 100));
    const third = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(third.status, /^HTTP\/1\.1 200/);
    third.socket.destroy();
    await ctx.stop();
  });

  it('un túnel se corta al pasar su tiempo máximo de vida', async () => {
    const ctx = await startProxy({ maxLifetimeMs: 150 });
    const { status, socket } = await connectVia(ctx.port, 'api.anthropic.com:443');
    assert.match(status, /^HTTP\/1\.1 200/);
    const closed = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 2000);
      socket.on('close', () => { clearTimeout(timer); resolve(true); });
    });
    assert.equal(closed, true);
    await ctx.stop();
  });

  it('el registro tiene host y bytes, y NUNCA el contenido', async () => {
    const lines = [];
    const ctx = await startProxy({ log: (line) => lines.push(JSON.stringify(line)) });
    const { socket } = await connectVia(ctx.port, 'api.anthropic.com:443');
    await new Promise((resolve) => { socket.once('data', resolve); socket.write('TOKEN-SECRETO-sk-ant-oat01-abc'); });
    socket.destroy();
    await new Promise((resolve) => setTimeout(resolve, 100));
    const all = lines.join('\n');
    assert.match(all, /api\.anthropic\.com/);
    assert.match(all, /bytesUp/);
    assert.doesNotMatch(all, /TOKEN-SECRETO|sk-ant/);
    await ctx.stop();
  });
});

describe('arranque como programa', () => {
  const server = fileURLToPath(new URL('./server.mjs', import.meta.url));

  /** Arranca `node <script>` y devuelve cuando escucha (o falla con lo que salió). */
  async function startAndProbe(script) {
    const port = 39000 + Math.floor(Math.random() * 500);
    const child = spawn('node', [script], {
      env: { ...process.env, PORT: String(port), ALLOWED_HOSTS: 'api.anthropic.com' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { output += chunk; });
    const exited = new Promise((resolve) => child.once('exit', (code) => resolve(code)));
    try {
      const listening = await Promise.race([
        new Promise((resolve) => {
          const timer = setInterval(() => {
            if (output.includes('"event":"listening"')) { clearInterval(timer); resolve(true); }
          }, 50);
        }),
        exited.then(() => false),
        new Promise((resolve) => setTimeout(() => resolve(false), 5000)),
      ]);
      // Y de verdad acepta conexiones.
      let accepts = false;
      if (listening) {
        accepts = await new Promise((resolve) => {
          const socket = net.connect(port, '127.0.0.1', () => { socket.destroy(); resolve(true); });
          socket.on('error', () => resolve(false));
        });
      }
      return { listening, accepts, output };
    } finally {
      child.kill();
    }
  }

  it('directo: escucha y acepta conexiones', async () => {
    const result = await startAndProbe(server);
    assert.equal(result.listening, true, result.output);
    assert.equal(result.accepts, true);
  });

  it('por un enlace simbólico (cómo lo monta un ConfigMap): escucha igual (regresión del CrashLoop del primer despliegue)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'claude-egress-'));
    const link = join(dir, 'server.mjs');
    symlinkSync(server, link);
    const result = await startAndProbe(link);
    assert.equal(result.listening, true, result.output);
    assert.equal(result.accepts, true);
  });

  it('importarlo (como hacen las pruebas) NO arranca ningún servidor', async () => {
    const child = spawn('node', ['-e', `import('${server}').then(() => setTimeout(() => process.exit(0), 300))`], { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    const code = await new Promise((resolve) => child.once('exit', resolve));
    assert.equal(code, 0);
    assert.doesNotMatch(output, /listening/);
  });
});

after(() => {});

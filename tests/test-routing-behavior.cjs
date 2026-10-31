// Real-core, loopback-only tests of generated routing matchers and sniffed targets.
// Only transport endpoints, local DNS, and rule-set download locations are replaced.
// Usage: node tests/test-routing-behavior.cjs --xray PATH --singbox PATH
//        [--bash PATH] [--jq-dir PATH] [--temp-root PATH] [--shared true]
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const options = {};
for (let i = 2; i < process.argv.length; i += 2) options[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
if (!options.xray || !options.singbox) throw new Error('--xray and --singbox binaries are required');
const repoDir = path.resolve(__dirname, '..');
const tempRoot = path.resolve(options['temp-root'] || process.env.AGSBX_TEST_TMPDIR || require('node:os').tmpdir());
fs.mkdirSync(tempRoot, { recursive: true });
const testDir = fs.mkdtempSync(path.join(tempRoot, 'argosbx-behavior-'));
const records = [];
const sockets = new Set();
const servers = [];
const children = [];
let failures = 0;
let assertions = 0;
function listen(server) { return new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => { servers.push(server); resolve(server.address().port); }); }); }
async function markerProxy(label) {
  return listen(net.createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    let state = 0; let buffered = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffered = Buffer.concat([buffered, chunk]);
      if (state === 0) {
        if (buffered.length < 2 || buffered.length < 2 + buffered[1]) return;
        buffered = buffered.subarray(2 + buffered[1]); socket.write(Buffer.from([5, 0])); state = 1;
      }
      if (state === 1) {
        if (buffered.length < 5) return;
        let host, end;
        if (buffered[3] === 3) { end = 5 + buffered[4]; if (buffered.length < end + 2) return; host = buffered.subarray(5, end).toString(); }
        else if (buffered[3] === 1) { end = 8; if (buffered.length < end + 2) return; host = [...buffered.subarray(4, 8)].join('.'); }
        else if (buffered[3] === 4) { end = 20; if (buffered.length < end + 2) return; host = buffered.subarray(4, 20).toString('hex'); }
        else { socket.destroy(); return; }
        records.push({ route: label, target: host, port: buffered.readUInt16BE(end) });
        buffered = buffered.subarray(end + 2); socket.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, 0, 0])); state = 2;
      }
      if (state === 2 && buffered[0] === 0x16) { socket.end(); state = 3; }
      if (state === 2 && buffered.includes(Buffer.from('\r\n\r\n'))) {
        const body = label;
        socket.end(`HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`); state = 3;
      }
    });
  }));
}
async function dnsStub() {
  return listen(net.createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    let data = Buffer.alloc(0);
    socket.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      while (data.length >= 2 && data.length >= data.readUInt16BE(0) + 2) {
        const length = data.readUInt16BE(0), query = data.subarray(2, length + 2); data = data.subarray(length + 2);
        let pos = 12; while (query[pos] && pos < query.length) pos += query[pos] + 1; pos++;
        const queryType = query.readUInt16BE(pos), questionEnd = pos + 4;
        const header = Buffer.from(query.subarray(0, 12)); header.writeUInt16BE(0x8180, 2); header.writeUInt16BE(queryType === 1 ? 1 : 0, 6); header.writeUInt32BE(0, 8);
        const answer = queryType === 1 ? Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 2]) : Buffer.alloc(0);
        const reply = Buffer.concat([header, query.subarray(12, questionEnd), answer]); const prefix = Buffer.alloc(2); prefix.writeUInt16BE(reply.length);
        socket.write(Buffer.concat([prefix, reply]));
      }
    });
  }));
}
async function reservePort() { const server = net.createServer(); const port = await listen(server); await new Promise(r => server.close(r)); return port; }
function reader(socket) {
  let bytes = Buffer.alloc(0), ended = false, failure = null; const waiters = new Set();
  const wake = () => { for (const waiter of waiters) waiter(); waiters.clear(); };
  socket.on('data', chunk => { bytes = Buffer.concat([bytes, chunk]); wake(); });
  socket.on('end', () => { ended = true; wake(); }); socket.on('close', () => { ended = true; wake(); }); socket.on('error', error => { failure = error; wake(); });
  return {
    async read(n) { while (bytes.length < n) { if (failure) throw failure; if (ended) throw Error('Unexpected EOF'); await new Promise(r => waiters.add(r)); } const result = bytes.subarray(0, n); bytes = bytes.subarray(n); return result; },
    async finish() { while (!ended) { if (failure) throw failure; await new Promise(r => waiters.add(r)); } return bytes.toString(); }
  };
}
function clientHello(hostname) {
  const host = Buffer.from(hostname);
  const name = Buffer.concat([Buffer.from([0, host.length >> 8, host.length & 255]), host]);
  const names = Buffer.concat([Buffer.from([name.length >> 8, name.length & 255]), name]);
  const extension = Buffer.concat([Buffer.from([0, 0, names.length >> 8, names.length & 255]), names]);
  const hello = Buffer.concat([Buffer.from([3, 3]), Buffer.alloc(32, 1), Buffer.from([0, 0, 2, 0, 0x2f, 1, 0, extension.length >> 8, extension.length & 255]), extension]);
  const handshake = Buffer.concat([Buffer.from([1, 0, hello.length >> 8, hello.length & 255]), hello]);
  return Buffer.concat([Buffer.from([0x16, 3, 1, handshake.length >> 8, handshake.length & 255]), handshake]);
}
async function sendRequest(port, hostname, target = hostname, payloadMode = 'http') {
  const socket = net.createConnection({ host: '127.0.0.1', port });
  const stream = reader(socket); const timeout = setTimeout(() => socket.destroy(Error('Request timeout')), 5000);
  try {
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
    socket.write(Buffer.from([5, 1, 0])); const greeting = await stream.read(2); if (greeting[1] !== 0) throw Error('SOCKS greeting rejected');
    const host = net.isIP(target) === 4 ? Buffer.from([1, ...target.split('.').map(Number)]) : Buffer.concat([Buffer.from([3, Buffer.byteLength(target)]), Buffer.from(target)]);
    const request = Buffer.concat([Buffer.from([5, 1, 0]), host, Buffer.from([0, 80])]);
    socket.write(request);
    const header = await stream.read(4); if (header[1] !== 0) throw Error('SOCKS connect rejected: ' + header[1]);
    const addressSize = header[3] === 1 ? 4 : header[3] === 4 ? 16 : (await stream.read(1))[0]; await stream.read(addressSize + 2);
    socket.write(payloadMode === 'tls' ? clientHello(hostname) : Buffer.from(`GET / HTTP/1.1\r\nHost: ${hostname}\r\nConnection: close\r\n\r\n`));
    return await stream.finish();
  } finally { clearTimeout(timeout); socket.destroy(); }
}
async function waitReady(port, child) {
  const deadline = Date.now() + 6000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw Error('Core exited with code ' + child.exitCode);
    try { await new Promise((resolve, reject) => { const socket = net.createConnection({ host: '127.0.0.1', port }); socket.once('connect', () => { socket.destroy(); resolve(); }); socket.once('error', reject); }); return; }
    catch { await new Promise(r => setTimeout(r, 100)); }
  }
  throw Error('Core did not start');
}
function runSync(binary, args, extra = {}) {
  const result = spawnSync(binary, args, { cwd: repoDir, encoding: 'utf8', windowsHide: true, ...extra });
  if (result.status !== 0) throw Error(`Command failed: ${binary} ${args.join(' ')}\n${result.stdout || ''}${result.stderr || ''}${result.error || ''}`);
}
function localizeSing(config, dnsPort) {
  config.dns.servers = config.dns.servers.map(server => ({ type: 'tcp', tag: server.tag, server: '127.0.0.1', server_port: dnsPort }));
  config.route.rule_set = config.route.rule_set.map(rule => ({ type: 'local', tag: rule.tag, format: 'binary', path: path.join(testDir, rule.tag === 'geosite-openai' ? 'openai.srs' : 'google-gemini.srs').replaceAll('\\', '/') }));
}
function socksOutbound(core, tag, port) {
  return core === 'xray'
    ? { protocol: 'socks', tag, settings: { servers: [{ address: '127.0.0.1', port }] } }
    : { type: 'socks', tag, server: '127.0.0.1', server_port: port, version: '5' };
}
function assertShared(description, condition) {
  assertions++;
  if (!condition) { failures++; console.log(`not ok ${assertions} - shared: ${description}`); return; }
  console.log(`ok ${assertions} - shared: ${description}`);
}
function startCore(binary, configPath, name) {
  let log = '';
  const child = spawn(binary, ['run', '-c', configPath], { cwd: testDir, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', d => { log += d; }); child.stderr.on('data', d => { log += d; });
  return { child, saveLog() { fs.writeFileSync(path.join(testDir, name + '.log'), log); } };
}
async function testSharedCores(directPort, warpPort, dnsPort) {
  const xray = JSON.parse(fs.readFileSync(path.join(testDir, 'xray.json'), 'utf8'));
  const sing = JSON.parse(fs.readFileSync(path.join(testDir, 'singbox.json'), 'utf8'));
  const bridge = xray.inbounds.find(i => i.tag === 'warp-shared-in');
  const forced = xray.routing.rules[0];
  const relay = sing.outbounds.find(o => o.tag === 'warp-out');
  assertShared('exactly one WireGuard owner across both generated configs',
    xray.outbounds.filter(o => o.protocol === 'wireguard').length === 1 &&
    (sing.endpoints || []).filter(o => o.type === 'wireguard').length === 0 &&
    sing.outbounds.filter(o => o.type === 'wireguard').length === 0);
  assertShared('Xray shared gateway listens only on loopback', bridge && bridge.listen === '127.0.0.1' && bridge.protocol === 'socks');
  assertShared('shared gateway traffic is forced through the owner WARP outbound',
    forced.outboundTag === 'warp-out' && forced.inboundTag.includes('warp-shared-in'));
  assertShared('sing-box relay targets the actual Xray gateway',
    relay.type === 'socks' && relay.server === '127.0.0.1' && relay.server_port === bridge.port);
  if (failures) throw Error('Shared production topology is invalid');
  localizeSing(sing, dnsPort);
  const nativeXrayPath = path.join(testDir, 'shared-xray.native.json'), nativeSingPath = path.join(testDir, 'shared-singbox.native.json');
  fs.writeFileSync(nativeXrayPath, JSON.stringify(xray)); fs.writeFileSync(nativeSingPath, JSON.stringify(sing));
  runSync(path.resolve(options.xray), ['run', '-test', '-c', nativeXrayPath]); assertShared('official Xray accepts production shared topology', true);
  runSync(path.resolve(options.singbox), ['check', '-c', nativeSingPath]); assertShared('official sing-box accepts production shared topology', true);
  const xrayPort = await reservePort(), singPort = await reservePort();
  xray.inbounds.find(i => i.tag === 'fixture-in').port = xrayPort;
  sing.inbounds.find(i => i.tag === 'fixture-in').listen_port = singPort;
  xray.log = { loglevel: 'warning' }; sing.log = { level: 'warn' };
  // Replace only the owner's final WG transport with a local marker; the
  // sing-box WARP relay still traverses the real running Xray gateway.
  xray.outbounds = xray.outbounds.map(out => socksOutbound('xray', out.tag, out.tag === 'direct' ? directPort : warpPort));
  sing.outbounds = sing.outbounds.map(out => out.tag === 'direct' ? socksOutbound('singbox', out.tag, directPort) : out);
  const xrayPath = path.join(testDir, 'shared-xray.run.json'), singPath = path.join(testDir, 'shared-singbox.run.json');
  fs.writeFileSync(xrayPath, JSON.stringify(xray)); fs.writeFileSync(singPath, JSON.stringify(sing));
  const owner = startCore(path.resolve(options.xray), xrayPath, 'shared-xray');
  const relayCore = startCore(path.resolve(options.singbox), singPath, 'shared-singbox');
  try {
    await waitReady(xrayPort, owner.child); await waitReady(bridge.port, owner.child); await waitReady(singPort, relayCore.child);
    const cases = [
      ['OpenAI domain', 'api.openai.com', 'warp'],
      ['Gemini domain', 'gemini.google.com', 'warp'],
      ['ordinary Google remains direct', 'www.google.com', 'direct'],
      ['HTTP Host selects shared WARP and preserves IP', 'api.openai.com', 'warp', '203.0.113.10', 'http'],
      ['TLS SNI selects shared WARP and preserves IP', 'api.openai.com', 'warp', '203.0.113.10', 'tls']
    ];
    for (const [core, port] of [['xray', xrayPort], ['singbox', singPort]]) {
      for (const [description, hostname, route, target, mode] of cases) {
        records.length = 0; assertions++;
        try {
          const body = await sendRequest(port, hostname, target, mode);
          const record = records.at(-1), expectedTarget = target || (route === 'warp' ? hostname : undefined);
          if (!record || record.route !== route || (mode !== 'tls' && !body.endsWith(route)) || (expectedTarget && record.target !== expectedTarget))
            throw Error(`expected ${route}${expectedTarget ? ' to ' + expectedTarget : ''}, observed ${JSON.stringify(record)}`);
          console.log(`ok ${assertions} - shared ${core}: ${description} (${record.route}, ${record.target})`);
        } catch (error) { failures++; console.log(`not ok ${assertions} - shared ${core}: ${description}: ${error.message}`); }
      }
    }
  } finally { owner.child.kill(); relayCore.child.kill(); owner.saveLog(); relayCore.saveLog(); }
}
async function testCore(name, binary, directPort, warpPort, dnsPort) {
  const configPath = path.join(testDir, name + '.json'); const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const inboundPort = await reservePort();
  if (name === 'xray') {
    config.log = { loglevel: 'warning' }; config.inbounds[0].port = inboundPort;
    config.outbounds = config.outbounds.map(out => ({ protocol: 'socks', tag: out.tag, settings: { servers: [{ address: '127.0.0.1', port: out.tag === 'direct' ? directPort : warpPort }] } }));
  } else {
    config.log = { level: options.debug ? 'debug' : 'warn' }; config.inbounds[0].listen_port = inboundPort;
    config.outbounds = config.outbounds.map(out => ({ type: 'socks', tag: out.tag, server: '127.0.0.1', server_port: out.tag === 'direct' ? directPort : warpPort, version: '5' }));
    config.dns.servers = config.dns.servers.map(server => ({ type: 'tcp', tag: server.tag, server: '127.0.0.1', server_port: dnsPort }));
    config.route.rule_set = config.route.rule_set.map(rule => ({ type: 'local', tag: rule.tag, format: 'binary', path: path.join(testDir, rule.tag === 'geosite-openai' ? 'openai.srs' : 'google-gemini.srs').replaceAll('\\', '/') }));
  }
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  let log = ''; const child = spawn(binary, name === 'xray' ? ['run', '-c', configPath] : ['run', '-c', configPath], { cwd: testDir, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child); child.stdout.on('data', d => { log += d; }); child.stderr.on('data', d => { log += d; });
  try {
    await waitReady(inboundPort, child);
    const cases = [
      ['exact domain', 'exact.ai.fixture', 'warp'],
      ['exact domain does not include subdomains', 'sub.exact.ai.fixture', 'direct'],
      ['suffix apex', 'openai.com', 'warp'],
      ['suffix subdomain', 'api.openai.com', 'warp'],
      ['suffix respects label boundary', 'notopenai.com', 'direct'],
      ['keyword', 'foo-keyword-ai.example', 'warp'],
      ['regular expression', 'regex-42.ai.fixture', 'warp'],
      ['regular expression negative', 'regex-x.ai.fixture', 'direct'],
      ['Gemini exact', 'generativelanguage.googleapis.com', 'warp'],
      ['Gemini suffix', 'gemini.google.com', 'warp'],
      ['ordinary Google', 'www.google.com', 'direct'],
      ['leading-dot suffix excludes apex', 'subonly.ai.fixture', 'direct'],
      ['leading-dot suffix includes subdomain', 'a.subonly.ai.fixture', 'warp'],
      ['sniffed HTTP AI IP target preserves destination', 'api.openai.com', 'warp', '203.0.113.10', '203.0.113.10'],
      ['sniffed TLS AI IP target preserves destination', 'api.openai.com', 'warp', '203.0.113.10', '203.0.113.10', 'tls']
    ];
    for (const [description, hostname, expectedRoute, target, explicitTarget, payloadMode] of cases.filter(c => !options.case || c[0].includes(options.case))) {
      records.length = 0; assertions++;
      try {
        const expectedTarget = explicitTarget || (expectedRoute === 'warp' ? hostname : undefined);
        const body = await sendRequest(inboundPort, hostname, target, payloadMode); const record = records.at(-1);
        if (!record || record.route !== expectedRoute || (payloadMode !== 'tls' && !body.endsWith(expectedRoute)) || (expectedTarget && record.target !== expectedTarget)) throw Error(`expected route=${expectedRoute}${expectedTarget ? ' target=' + expectedTarget : ''}, observed=${JSON.stringify(record)}`);
        console.log(`ok ${assertions} - ${name}: ${description} (${record.route}, ${record.target})`);
      } catch (error) { failures++; console.log(`not ok ${assertions} - ${name}: ${description}: ${error.message}; records=${JSON.stringify(records)}`); if(options.debug) console.log(log); }
    }
  } finally { child.kill(); fs.writeFileSync(path.join(testDir, name + '.log'), log); }
}
(async () => {
  try {
    const directPort = await markerProxy('direct'), warpPort = await markerProxy('warp'), dnsPort = await dnsStub();
    runSync(options.bash || 'bash', [path.join(repoDir, 'tests/fixture-routing-configs.sh'), testDir.replaceAll('\\', '/'), String(warpPort)], { env: { ...process.env, AGSBX_TEST_JQ_DIR: options['jq-dir'] ? path.resolve(options['jq-dir']) : '', AGSBX_TEST_SHARED: options.shared === 'true' ? '1' : '0' } });
    for (const category of ['openai', 'google-gemini']) runSync(path.resolve(options.singbox), ['rule-set', 'compile', path.join(testDir, category + '.json'), '-o', path.join(testDir, category + '.srs')]);
    if (options.shared === 'true') await testSharedCores(directPort, warpPort, dnsPort);
    else {
      if (!options.core || options.core === 'xray') await testCore('xray', path.resolve(options.xray), directPort, warpPort, dnsPort);
      if (!options.core || options.core === 'singbox') await testCore('singbox', path.resolve(options.singbox), directPort, warpPort, dnsPort);
    }
    console.log(`${failures ? 'FAIL' : 'PASS'}: ${assertions} real-core routing assertions, ${failures} failed`);
    if (failures) { console.log('Failure fixtures: ' + testDir); process.exitCode = 1; }
  } catch (error) { console.error(error.stack); console.error('Failure fixtures: ' + testDir); failures++; process.exitCode = 1; }
  finally {
    for (const child of children) child.kill();
    for (const socket of sockets) socket.destroy();
    await Promise.all(servers.map(server => new Promise(resolve => { if (server.listening) server.close(resolve); else resolve(); })));
    if (!failures) {
      const resolved = path.resolve(testDir);
      if (path.dirname(resolved) !== tempRoot || !path.basename(resolved).startsWith('argosbx-behavior-')) throw Error('Unsafe temporary cleanup target');
      fs.rmSync(resolved, { recursive: true });
    }
  }
})();

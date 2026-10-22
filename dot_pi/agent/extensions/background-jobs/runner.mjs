// Detached supervisor + anchored process group. No saved PID is ever a signal target.
import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

process.umask(0o077);
const self = fileURLToPath(import.meta.url);
if (process.argv[2] === '--group') {
  // This live handle anchors the group even when RTK exits before its descendants.
  // Only the supervisor signals it; ignore graceful signals received by the group.
  process.on('SIGINT', () => {});
  process.on('SIGTERM', () => {});
  process.on('disconnect', () => process.kill(-process.pid, 'SIGKILL'));
  process.once('message', ({ shell, command, cwd }) => {
    const child = spawn('rtk', ['run', '--shell', shell, '-c', command], {
      cwd, stdio: ['pipe', 'inherit', 'inherit'],
    });
    process.stdin.pipe(child.stdin);
    child.stdin.on('error', () => {}); // RTK can exit before a queued stdin write.
    let error;
    child.once('spawn', () => process.send?.({ ready: true }));
    child.on('error', e => { error = e.message; });
    child.on('close', (exitCode, signal) => {
      process.stdin.unpipe(child.stdin);
      process.send?.({ exitCode, signal, ...(error ? { error } : {}) });
      // Stay alive on IPC until the supervisor reaps this entire group.
    });
  });
} else {
  const dir = process.argv[2];
  const job = JSON.parse(fs.readFileSync(join(dir, 'job.json'), 'utf8'));
  const config = JSON.parse(fs.readFileSync(join(dir, 'launch.json'), 'utf8'));
  fs.unlinkSync(join(dir, 'launch.json'));
  let state = { state: 'starting', exitCode: null, signal: null };
  let group, ready = false, stopping = false, forceRequested = false, finishing = false, outcome, forceTimer;
  const sockets = new Set();
  const save = () => {
    fs.writeFileSync(join(dir, 'state.tmp'), JSON.stringify(state), { mode: 0o600 });
    fs.renameSync(join(dir, 'state.tmp'), join(dir, 'state.json'));
  };
  const signalGroup = signal => {
    // A live child handle, not a persisted pid, proves ownership of the anchor.
    if (!group || group.exitCode !== null || group.signalCode !== null) return;
    try { process.kill(-group.pid, signal); }
    catch (e) { if (e.code !== 'ESRCH') throw e; }
  };
  const stop = force => {
    if (finishing) return;
    stopping = true; forceRequested ||= force;
    state.state = 'stopping'; save();
    // Do not signal until the anchor has installed its signal/disconnect handlers.
    if (!ready) return;
    signalGroup(forceRequested ? 'SIGTERM' : 'SIGINT');
    if (forceRequested && !forceTimer) forceTimer = setTimeout(() => {
      finishing = true;
      outcome = { exitCode: null, signal: 'SIGKILL' };
      signalGroup('SIGKILL');
    }, 1000);
  };
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    socket.setEncoding('utf8');
    socket.setTimeout(3000, () => socket.destroy());
    let input = '';
    socket.on('data', chunk => {
      input += chunk.toString('utf8');
      if (Buffer.byteLength(input) > 65536) { socket.destroy(); return; }
      if (!input.includes('\n')) return;
      socket.pause(); // Exactly one request per connection.
      const reply = data => socket.end(JSON.stringify(data) + '\n');
      try {
        const request = JSON.parse(input.slice(0, input.indexOf('\n')));
        if (request.token !== job.token) throw new Error('Control authentication failed.');
        if (request.action === 'status') { reply(state); return; }
        if (request.action === 'stop') { stop(!!request.force); reply(state); return; }
        if (request.action !== 'send' || typeof request.text !== 'string' || request.text.length > 8193)
          throw new Error('Invalid control request.');
        if (state.state !== 'running') throw new Error('Job is not running.');
        group.stdin.write(request.text, error => reply(error ? { error: error.message } : state));
      } catch (e) { reply({ error: e.message }); }
    });
  });
  const finish = () => {
    clearTimeout(forceTimer);
    state = { state: outcome ? (stopping ? 'stopped' : outcome.error ? 'failed' : 'exited') : 'lost',
      exitCode: null, signal: null, ...outcome, ended: new Date().toISOString() };
    save();
    for (const socket of sockets) socket.destroy();
    server.close(() => {
      fs.rmSync(job.socketDir, { recursive: true, force: true });
    });
  };
  server.on('error', error => {
    state = { state: 'failed', exitCode: null, signal: null, error: error.message }; save();
    // This private directory is unique to this launch; never unlink another socket.
    fs.rmSync(job.socketDir, { recursive: true, force: true });
    process.exitCode = 1;
  });
  server.listen(join(job.socketDir, 'control.sock'), () => {
    fs.chmodSync(join(job.socketDir, 'control.sock'), 0o600);
    const output = fs.openSync(join(dir, 'output.log'), 'a', 0o600);
    group = spawn(process.execPath, [self, '--group'], {
      detached: true, cwd: job.cwd, stdio: ['pipe', output, output, 'ipc'],
    });
    fs.closeSync(output);
    group.stdin.on('error', () => {});
    group.on('error', error => { outcome = { error: error.message }; });
    group.on('message', result => {
      if (finishing) return;
      if (result.ready) {
        ready = true;
        if (stopping) stop(forceRequested);
        else { state.state = 'running'; save(); }
        return;
      }
      finishing = true; outcome = result;
      // Anchor is still alive: kill any descendants before releasing ownership.
      signalGroup('SIGKILL');
    });
    group.on('close', finish);
    group.once('spawn', () => group.send({ ...config, cwd: job.cwd }));
  });
  process.on('SIGINT', () => stop(true));
  process.on('SIGTERM', () => stop(true));
}

import net from 'net';
import fs from 'fs';
const HOST = '192.168.1.63';
const PORT = 8085;
const outPath = process.argv[2] || 'telnet.log';
const stream = fs.createWriteStream(outPath, { flags: 'a' });
const sock = net.connect(PORT, HOST, () => {
  console.error('connected to ' + HOST + ':' + PORT);
});
sock.on('data', (d) => { stream.write(d); });
sock.on('error', (e) => { console.error('ERR: ' + e.message); process.exit(1); });
function cleanup() {
  console.error('closing socket');
  sock.destroy();
  stream.end();
  setTimeout(() => process.exit(0), 200);
}
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

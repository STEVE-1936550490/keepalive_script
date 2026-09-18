// Emulate a proxy keeping the client connection open after upstream CGI exits.
// Run against a live dashboard; no password or session is used.
const net = require('node:net');
const assert = require('node:assert/strict');
const upstreamPort = Number(process.env.TEST_DASHBOARD_PORT || 3000);
const sockets = new Set();
const server = net.createServer(client => {
    sockets.add(client);
    client.once('data', () => {
        const upstream = net.connect(upstreamPort, '127.0.0.1', () => {
            upstream.end('GET /cgi-bin/state.sh HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n');
        });
        sockets.add(upstream);
        const chunks = [];
        upstream.on('data', chunk => chunks.push(chunk));
        upstream.on('end', () => client.write(Buffer.concat(chunks)));
        upstream.on('error', () => client.destroy());
    });
});
(async () => {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
        const response = await fetch(`http://127.0.0.1:${server.address().port}/`, {signal: AbortSignal.timeout(2000)});
        assert.equal(response.status, 401);
        assert.equal((await response.json()).error, 'login_required');
        console.log('PASS: CGI JSON completes even when a proxy keeps the TCP connection open');
    } finally {
        for (const socket of sockets) socket.destroy();
        server.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });

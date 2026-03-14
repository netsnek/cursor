#!/usr/bin/env node
/**
 * Lightweight CORS proxy for Cursor API calls.
 *
 * The desktop workbench (running in the browser) needs to call
 * api2/api3/api4.cursor.sh for model lists, auth, completions, etc.
 * These calls are blocked by CORS. This proxy forwards requests
 * and adds the necessary CORS headers.
 *
 * The browser shim sets X-Proxy-Host to the original target hostname.
 *
 * Usage: node cursor-cors-proxy.js [port]
 * Default port: 9080
 */
const http = require('http');
const https = require('https');

const PORT = parseInt(process.argv[2] || '9080', 10);
const DEFAULT_TARGET = 'api2.cursor.sh';
// Allow all Cursor API domains including agent subdomains of api5
// Allow Cursor API domains + Statsig feature flag domains (needed for model loading)
const _allowedRe = /^(?:api[2-5]\.cursor\.sh|[a-z0-9-]+\.api5\.cursor\.sh|api\.statsigcdn\.com|featureassets\.org|prodregistryv2\.org|statsigapi\.net)$/;

const server = http.createServer((req, res) => {
    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
        res.writeHead(204, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers': req.headers['access-control-request-headers'] || '*',
            'Access-Control-Max-Age': '86400',
        });
        res.end();
        return;
    }

    // Determine target host from X-Proxy-Host header
    const targetHost = req.headers['x-proxy-host'];
    const target = (targetHost && _allowedRe.test(targetHost)) ? targetHost : DEFAULT_TARGET;

    // Collect request body
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
        const body = Buffer.concat(chunks);

        // Forward headers, removing hop-by-hop and proxy headers
        const fwdHeaders = { ...req.headers };
        delete fwdHeaders['host'];
        delete fwdHeaders['origin'];
        delete fwdHeaders['referer'];
        delete fwdHeaders['x-proxy-host'];
        delete fwdHeaders['connection'];
        fwdHeaders['host'] = target;

        const options = {
            hostname: target,
            port: 443,
            path: req.url,
            method: req.method,
            headers: fwdHeaders,
        };

        const proxyReq = https.request(options, proxyRes => {
            // Add CORS headers to the response
            const headers = { ...proxyRes.headers };
            headers['access-control-allow-origin'] = '*';
            headers['access-control-expose-headers'] = '*';
            delete headers['access-control-allow-credentials'];

            res.writeHead(proxyRes.statusCode, headers);
            proxyRes.pipe(res);
        });

        proxyReq.on('error', err => {
            console.error(`Proxy error (${target}): ${err.message}`);
            res.writeHead(502, {
                'Access-Control-Allow-Origin': '*',
                'Content-Type': 'text/plain',
            });
            res.end(`Proxy error: ${err.message}`);
        });

        if (body.length > 0) {
            proxyReq.write(body);
        }
        proxyReq.end();
    });
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`Cursor CORS proxy listening on http://127.0.0.1:${PORT}`);
    console.log(`Forwarding to: api[2-5].cursor.sh and agent subdomains`);
});

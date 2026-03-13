/*!--------------------------------------------------------
 * Cursor Web — desktop workbench in browser with IPC bridge
 *--------------------------------------------------------*/

// === IPC Binary Protocol (varint-based, matching VS Code's MQ serialization) ===
// Tags: Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4, Object=5, Int=6, Uint8Array=7
const MQ = { Undefined: 0, String: 1, Buffer: 2, VSBuffer: 3, Array: 4, Object: 5, Int: 6, Uint8Array: 7 };
const _enc = new TextEncoder();
const _dec = new TextDecoder();

// Varint encoding (same as protobuf LEB128)
function varintSize(n) { if (n === 0) return 1; let s = 0; for (let v = n; v !== 0; v = v >>> 7) s++; return s; }
function writeVarint(n) {
    if (n === 0) return new Uint8Array([0]);
    const sz = varintSize(n);
    const buf = new Uint8Array(sz);
    for (let i = 0; n !== 0; i++) { buf[i] = n & 127; n = n >>> 7; if (n > 0) buf[i] |= 128; }
    return buf;
}
function readVarint(buf, offset) {
    let value = 0;
    for (let shift = 0; ; shift += 7) {
        const b = buf[offset++];
        value |= (b & 127) << shift;
        if (!(b & 128)) break;
    }
    return { value, nextOffset: offset };
}

function concatBuffers(...bufs) {
    const total = bufs.reduce((s, b) => s + b.byteLength, 0);
    const result = new Uint8Array(total);
    let offset = 0;
    for (const b of bufs) { result.set(b, offset); offset += b.byteLength; }
    return result;
}

// Write functions (tag byte + varint length + data)
function writeUndefined() { return new Uint8Array([MQ.Undefined]); }
function writeInt(value) { return concatBuffers(new Uint8Array([MQ.Int]), writeVarint(value)); }
function writeString(str) {
    const encoded = _enc.encode(str);
    return concatBuffers(new Uint8Array([MQ.String]), writeVarint(encoded.length), encoded);
}
function writeObject(obj) {
    const encoded = _enc.encode(JSON.stringify(obj));
    return concatBuffers(new Uint8Array([MQ.Object]), writeVarint(encoded.length), encoded);
}
function writeBuffer(data) {
    return concatBuffers(new Uint8Array([MQ.Buffer]), writeVarint(data.length), data);
}
function writeArray(items) {
    const serialized = items.map(serializeValue);
    return concatBuffers(new Uint8Array([MQ.Array]), writeVarint(items.length), ...serialized);
}

// Read functions
function readValue(buf, offset) {
    if (offset >= buf.length) return { value: undefined, nextOffset: offset };
    const tag = buf[offset++];
    switch (tag) {
        case MQ.Undefined: return { value: undefined, nextOffset: offset };
        case MQ.Int: return readVarint(buf, offset);
        case MQ.String: {
            const { value: len, nextOffset: o } = readVarint(buf, offset);
            return { value: _dec.decode(buf.slice(o, o + len)), nextOffset: o + len };
        }
        case MQ.Buffer: case MQ.VSBuffer: case MQ.Uint8Array: {
            const { value: len, nextOffset: o } = readVarint(buf, offset);
            return { value: buf.slice(o, o + len), nextOffset: o + len };
        }
        case MQ.Object: {
            const { value: len, nextOffset: o } = readVarint(buf, offset);
            const str = _dec.decode(buf.slice(o, o + len));
            try { return { value: JSON.parse(str), nextOffset: o + len }; }
            catch { return { value: str, nextOffset: o + len }; }
        }
        case MQ.Array: {
            const { value: len, nextOffset: o } = readVarint(buf, offset);
            const arr = []; let pos = o;
            for (let i = 0; i < len; i++) { const r = readValue(buf, pos); arr.push(r.value); pos = r.nextOffset; }
            return { value: arr, nextOffset: pos };
        }
        default: return { value: undefined, nextOffset: offset };
    }
}

function serializeValue(v) {
    if (v === undefined) return writeUndefined();
    if (v === null) return writeUndefined();  // null → undefined in this protocol
    if (typeof v === 'boolean') return writeInt(v ? 1 : 0);
    if (typeof v === 'number') return writeInt(v);
    if (typeof v === 'string') return writeString(v);
    if (v instanceof Uint8Array) return writeBuffer(v);
    if (Array.isArray(v)) return writeArray(v);
    if (typeof v === 'object') return writeObject(v);
    return writeUndefined();
}

const ProtoType = {
    Request: 100, Cancel: 101, EventSubscribe: 102, EventDispose: 103,
    Initialize: 200, ResponseSuccess: 201, ResponseError: 202, EventFire: 300
};

// Protocol format: serialize(headerArray), serialize(body)
// Request header: [type, id, channelName, name], arg
// Response header: [type, id], data
// Init header: [type], undefined
function parseMessage(buf) {
    const headerR = readValue(buf, 0);
    const bodyR = readValue(buf, headerR.nextOffset);
    const header = headerR.value;
    if (!Array.isArray(header)) return null;
    return { type: header[0], id: header[1], channelName: header[2], name: header[3], arg: bodyR.value };
}

function buildResponse(type, id, data) {
    return concatBuffers(serializeValue([type, id]), serializeValue(data));
}

function buildInit() {
    return concatBuffers(serializeValue([ProtoType.Initialize]), writeUndefined());
}

function handleProtocolMessage(buf, respond) {
    const msg = parseMessage(buf);
    if (!msg) {
        showStatus?.(`[IPC] Unparseable message (${buf.length}B)`);
        return;
    }
    const { type, id, channelName, name, arg } = msg;

    if (type === ProtoType.Request) {
        const argStr = arg !== undefined ? JSON.stringify(arg)?.slice(0, 120) : '';
        showStatus?.(`[IPC] req ${channelName}.${name} id=${id} ${argStr}`);
        try {
            const result = handleChannelRequest(channelName, name, arg);
            respond(buildResponse(ProtoType.ResponseSuccess, id, result));
        } catch(e) {
            showStatus?.(`[IPC] ERROR ${channelName}.${name}: ${e.message}`);
            respond(buildResponse(ProtoType.ResponseError, id, { message: e.message, name: e.name }));
        }
    } else if (type === ProtoType.Cancel || type === ProtoType.EventDispose) {
        // Nothing to do
    } else if (type === ProtoType.EventSubscribe) {
        showStatus?.(`[IPC] eventSub ${channelName}.${name} id=${id}`);
    } else if (type === ProtoType.Initialize) {
        // Workbench sending init — ignore
    } else {
        showStatus?.(`[IPC] unhandled type=${type}`);
    }
}

// === Channel Handlers ===
function handleChannelRequest(channelName, methodName, arg) {
    switch (channelName) {
        case 'nativeHost': return handleNativeHost(methodName, arg);
        case 'storage': return handleStorage(methodName, arg);
        case 'policy': return handlePolicy(methodName);
        case 'keyboardLayout': return handleKeyboardLayout(methodName);
        case 'sign': return handleSign(methodName, arg);
        case 'workspaces': return handleWorkspaces(methodName);
        case 'userDataProfiles': return handleUserDataProfiles(methodName);
        case 'extensions': return handleExtensions(methodName, arg);
        case 'logger': return handleLogger(methodName, arg);
        case 'localFilesystem': return undefined;
        case 'utilityProcessWorker': return handleUtilityProcessWorker(methodName, arg);
        case 'watcher': return handleWatcher(methodName, arg);
        case 'userDataSyncAccount': return handleUserDataSync(methodName);
        case 'userDataSyncStoreManagement': return undefined;
        case 'tracing': return undefined;  // telemetry/tracing — ignore
        case 'abuse': return (methodName === 'getMachineId' || methodName === 'getMacMachineId') ? '' : undefined;
        case 'agentAnalyticsOperations': return undefined;
        case 'update': return (methodName === '_getInitialState') ? { type: 'idle' } : undefined;
        case 'tray': return undefined;  // system tray — N/A in browser
        case 'extensionGalleryManifest': return undefined;
        case 'extensionHostStarter': return undefined;
        case 'externalTerminal': return (methodName === 'getDefaultTerminalForPlatforms') ? {} : undefined;
        default:
            showStatus?.(`[IPC] unknown channel: ${channelName}.${methodName}`);
            return undefined;
    }
}

function handleNativeHost(method, arg) {
    switch (method) {
        case 'getWindowCount': return 1;
        case 'getWindows': return [{ id: 1, workspace: undefined, title: 'Cursor Web' }];
        case 'isMaximized': return false;
        case 'isFullScreen': return false;
        case 'hasFocus': return document.hasFocus();
        case 'getOSProperties': return { arch: 'arm64', platform: 'linux', release: 'web', hostname: 'localhost', type: 'Linux' };
        case 'getOSStatistics': return { totalmem: 8589934592, freemem: 4294967296 };
        case 'getOSVirtualMachineHint': return 0;
        case 'getOSColorScheme': return { dark: true, highContrast: false };
        case 'hasWSLFeatureInstalled': return false;
        case 'getProcessId': return 1;
        case 'resolveProxy': return undefined;
        case 'readClipboardText': return '';
        case 'readClipboardFindText': return '';
        case 'readClipboardBuffer': return new Uint8Array(0);
        case 'showMessageBox': {
            const opts = Array.isArray(arg) ? arg[1] : arg;
            if (opts?.detail) {
                const urlMatch = opts.detail.match(/https?:\/\/\S+/);
                if (urlMatch) window.open(urlMatch[0], '_blank');
            }
            return { response: 0, checkboxChecked: false };
        }
        case 'showOpenDialog': {
            const opts = Array.isArray(arg) ? arg[1] : arg;
            const label = opts?.title || 'Enter folder path to open';
            const path = window.prompt(label, '/home/snekmin');
            if (path) return { canceled: false, filePaths: [path] };
            return { canceled: true, filePaths: [] };
        }
        case 'showSaveDialog': return { canceled: true };
        case 'openExternal': {
            const url = Array.isArray(arg) ? arg[0] : arg;
            if (url) window.open(url, '_blank');
            return true;
        }
        case 'focusWindow': case 'maximizeWindow': case 'minimizeWindow':
        case 'unmaximizeWindow': case 'setMinimumSize': case 'setTitle':
            return undefined;
        default: return undefined;
    }
}
// Sign service: uses vsda WASM for connection handshake
let _vsdaModule = null;
let _vsdaLoading = null;
let _vsdaValidators = new Map();
let _vsdaNextId = 1;

async function _loadVsda() {
    if (_vsdaModule) return _vsdaModule;
    if (_vsdaLoading) return _vsdaLoading;
    _vsdaLoading = (async () => {
        try {
            const shimUrl = import.meta.url || '';
            const baseUrl = shimUrl.substring(0, shimUrl.lastIndexOf('/static/') + '/static/'.length);
            const wasmUrl = baseUrl + 'node_modules/vsda/rust/web/vsda_bg.wasm';
            const jsUrl = baseUrl + 'node_modules/vsda/rust/web/vsda.js';
            // Load the vsda JS (sets globalThis.vsda_web)
            await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                script.src = jsUrl;
                script.onload = resolve;
                script.onerror = reject;
                document.head.appendChild(script);
            });
            // Fetch WASM and init synchronously
            const wasmResp = await fetch(wasmUrl);
            const wasmBytes = await wasmResp.arrayBuffer();
            globalThis.vsda_web.initSync(wasmBytes);
            _vsdaModule = globalThis.vsda_web;
            showStatus?.('vsda WASM loaded for connection signing');
            return _vsdaModule;
        } catch (e) {
            showStatus?.('vsda WASM load failed: ' + e.message);
            return null;
        }
    })();
    return _vsdaLoading;
}

// Pre-load vsda
_loadVsda();

function handleSign(method, arg) {
    switch (method) {
        case 'createNewMessage': {
            const nonce = Array.isArray(arg) ? arg[0] : arg;
            if (_vsdaModule) {
                try {
                    const v = new _vsdaModule.validator();
                    const data = v.createNewMessage(nonce || '');
                    const id = String(_vsdaNextId++);
                    _vsdaValidators.set(id, v);
                    return { id, data };
                } catch (e) {
                    showStatus?.('vsda createNewMessage error: ' + e.message);
                }
            }
            return { id: '', data: nonce || '' };
        }
        case 'validate': {
            // arg = [{ id, data }, signedData]
            const msg = Array.isArray(arg) ? arg[0] : arg;
            const signedData = Array.isArray(arg) ? arg[1] : '';
            if (msg?.id && _vsdaValidators.has(msg.id)) {
                const v = _vsdaValidators.get(msg.id);
                _vsdaValidators.delete(msg.id);
                try {
                    const result = v.validate(signedData || '');
                    v.free();
                    return result === 'ok';
                } catch (e) {
                    v.free();
                    showStatus?.('vsda validate error: ' + e.message);
                }
            }
            return true;
        }
        case 'sign': {
            const value = Array.isArray(arg) ? arg[0] : (arg || '');
            if (_vsdaModule) {
                try { return _vsdaModule.sign(value); } catch {}
            }
            return value;
        }
        default: return undefined;
    }
}
// Storage: backed by localStorage, seeded from desktop Cursor's state.vscdb
const _storagePrefix = 'cursor-web-storage:';
function _storageGetAll() {
    const items = [];
    for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k.startsWith(_storagePrefix)) {
            items.push([k.slice(_storagePrefix.length), localStorage.getItem(k)]);
        }
    }
    return items;
}
function handleStorage(method, arg) {
    switch (method) {
        case 'getItems': return _storageGetAll();
        case 'updateItems': {
            if (arg?.insert) {
                for (const [k, v] of arg.insert) {
                    localStorage.setItem(_storagePrefix + k, v);
                }
            }
            if (arg?.delete) {
                for (const k of arg.delete) {
                    localStorage.removeItem(_storagePrefix + k);
                }
            }
            return undefined;
        }
        case 'optimize': case 'close': return undefined;
        case 'isUsed': return true;
        default: return undefined;
    }
}
function handlePolicy(method) {
    return (method === 'getPolicyDefinitions' || method === 'getPolicies') ? {} : undefined;
}
function handleKeyboardLayout(method) {
    if (method === 'getKeyboardLayoutData' || method === 'getCurrentKeyboardLayoutData')
        return { keyboardLayoutInfo: { model: '', layout: 'de', variant: '', options: '', rules: '' }, keyboardMapping: {} };
    if (method === 'getCurrentKeyboardLayout')
        return { model: '', layout: 'de', variant: '', options: '', rules: '' };
    return undefined;
}
function handleWorkspaces(method) {
    return (method === 'getRecentlyOpened') ? { workspaces: [], files: [] } : undefined;
}
function handleUserDataProfiles(method) {
    if (method === 'getProfiles') return [];
    if (method === '_getInitialData') return { profiles: [], defaultProfile: null };
    return undefined;
}
function handleExtensions(method, arg) {
    switch (method) {
        case 'getExtensionsControlManifest': return { malicious: [], deprecated: {}, search: [], publisherMappings: {} };
        case 'getInstalled': return [];
        default: return undefined;
    }
}
function handleLogger(method, arg) {
    // createLogger, registerLogger, log — all are fire-and-forget style
    return undefined;
}
function handleUtilityProcessWorker(method, arg) {
    if (method === 'createWorker') return undefined;
    return undefined;
}
function handleWatcher(method, arg) {
    if (method === 'watch') return undefined;
    if (method === 'setVerboseLogging') return undefined;
    return undefined;
}
function handleUserDataSync(method) {
    if (method === '_getInitialData') return { account: undefined };
    return undefined;
}

// === MessagePort Protocol Handler ===
// The shared process / utility worker uses the same binary protocol over MessagePort
function setupProtocolPort(port) {
    let state = 0; // 0=wait-handshake, 1=wait-first-msg, 2=running
    port.onmessage = (event) => {
        const raw = event.data;
        const buf = raw instanceof Uint8Array ? raw : new Uint8Array(raw);

        if (state === 0) {
            // First message is the handshake buffer (a serialized string like "window:1,module:vs...")
            // Respond with init, then wait for actual protocol messages
            state = 1;
            showStatus?.(`[Port] Handshake (${buf.length}B), sending init...`);
            const initBuf = buildInit();
            port.postMessage(initBuf.buffer);
            return;
        }
        if (state === 1) {
            state = 2;
            // Second message might be another init from the workbench — check and skip
            const msg = parseMessage(buf);
            if (msg && msg.type === ProtoType.Initialize) {
                showStatus?.('[Port] Got workbench init, ready.');
                return;
            }
            // Otherwise it's a real message, fall through
        }

        handleProtocolMessage(buf, (resp) => {
            port.postMessage(resp.buffer);
        });
    };
    port.start();
}

// === IPC Renderer ===
const _ipcListeners = new Map();
function _fire(channel, ...args) {
    for (const fn of (_ipcListeners.get(channel) || [])) {
        try { fn({}, ...args); } catch(e) { console.warn('[IPC] listener error:', e); }
    }
}

globalThis.vscode = {
    context: { configuration: () => ({ product: globalThis._VSCODE_PRODUCT_JSON || {} }) },
    ipcRenderer: {
        send(channel, ...args) {
            showStatus?.(`IPC.send: ${channel}`);
            if (channel === 'vscode:hello') {
                setTimeout(() => {
                    showStatus?.('Sending IPC init (type 200)...');
                    _fire('vscode:message', buildInit());
                    showStatus?.('IPC init sent.');
                }, 0);
                return;
            }
            if (channel === 'vscode:message') {
                const buf = new Uint8Array(args[0]);
                handleProtocolMessage(buf, (resp) => {
                    queueMicrotask(() => _fire('vscode:message', resp));
                });
                return;
            }
        },
        invoke(channel, ...args) {
            showStatus?.(`IPC.invoke: ${channel}`);
            if (channel === 'vscode:fetchShellEnvironment' || channel === 'vscode:getShellEnvironment')
                return Promise.resolve({});
            return Promise.resolve(undefined);
        },
        on(channel, fn) {
            showStatus?.(`IPC.on: ${channel}`);
            if (!_ipcListeners.has(channel)) _ipcListeners.set(channel, []);
            _ipcListeners.get(channel).push(fn);
            return { dispose() { const a = _ipcListeners.get(channel); if(a) { const i = a.indexOf(fn); if(i>=0) a.splice(i,1); } } };
        },
        once(channel, fn) {
            const wrapped = (...args) => { fn(...args); d.dispose(); };
            const d = globalThis.vscode.ipcRenderer.on(channel, wrapped);
            return d;
        },
        removeListener(channel, fn) {
            const a = _ipcListeners.get(channel);
            if (a) { const i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); }
        },
    },
    ipcMessagePort: {
        acquire(responseChannel, nonce) {
            showStatus?.(`IPC.port.acquire: ${responseChannel} nonce=${nonce}`);
            // The workbench listens on window "message" for { data: nonce, ports: [port], source: window }
            const mc = new MessageChannel();
            // Set up the port to handle the IPC protocol (init + channel requests)
            setupProtocolPort(mc.port2);
            setTimeout(() => {
                showStatus?.('Posting MessagePort via window.postMessage...');
                window.postMessage(nonce, '*', [mc.port1]);
            }, 0);
        },
    },
    webFrame: { setZoomLevel() {} },
    process: {
        platform: 'linux', arch: 'arm64', env: {},
        versions: { node: '20.0.0', chrome: '120.0.0', electron: '32.0.0' },
        type: 'renderer', sandboxed: true, cwd: () => '/home/snekmin', pid: 1,
        on() {}, once() {}, removeListener() {}, emit() {},
        getHeapStatistics: () => ({}),
        getProcessMemoryInfo: () => Promise.resolve({ private: 0, shared: 0 }),
        shellEnv: () => Promise.resolve({}),
    },
};

// === Config ===
const configElement = document.getElementById('vscode-workbench-web-configuration');
const webConfig = JSON.parse(configElement?.getAttribute('data-settings') || '{}');

globalThis._VSCODE_PRODUCT_JSON = Object.assign({
    "quality": "stable", "licenseName": "MIT",
    "version": "2.6.19",
    "serverApplicationName": "cursor-server",
    "serverDataFolderName": ".cursor-server",
    "tunnelApplicationName": "cursor-tunnel",
    "urlProtocol": "cursor",
}, webConfig.productConfiguration || {});

globalThis._VSCODE_PACKAGE_JSON = {
    "name": "Cursor", "version": "2.6.19",
    "main": "./out/main.js", "type": "module", "private": true
};

// === Visible Status (console only) ===
function showStatus(msg) {
    console.warn('[CursorWeb] ' + msg);
}

// === Auth Token Seeding ===
async function seedAuthTokens() {
    // Clean up stale desktop layout keys that break web UI
    for (let i = localStorage.length - 1; i >= 0; i--) {
        const k = localStorage.key(i);
        if (k?.startsWith(_storagePrefix + 'cursor/') || k?.startsWith(_storagePrefix + 'cursor.')) {
            localStorage.removeItem(k);
        }
    }
    if (localStorage.getItem(_storagePrefix + 'cursorAuth/accessToken')) {
        showStatus('Auth tokens already in localStorage.');
        return;
    }
    try {
        const shimUrl = import.meta.url || document.currentScript?.src || '';
        const baseUrl = shimUrl.substring(0, shimUrl.lastIndexOf('/') + 1);
        const resp = await fetch(baseUrl + 'cursor-auth-seed.json');
        if (!resp.ok) { showStatus('No auth seed file (run patch-cursor-web.sh).'); return; }
        const tokens = await resp.json();
        for (const [key, value] of Object.entries(tokens)) {
            localStorage.setItem(_storagePrefix + key, value);
        }
        showStatus('Auth tokens seeded: ' + Object.keys(tokens).join(', '));
    } catch (e) {
        showStatus('Auth seed fetch failed: ' + e.message);
    }
}

// === Boot ===
performance.mark('code/willLoadWorkbenchMain');

async function boot() {
    try {
        await seedAuthTokens();
        await _loadVsda();
        showStatus('Loading desktop workbench...');
        const workbench = await import('../../../workbench/workbench.desktop.main.js');
        performance.mark('code/didLoadWorkbenchMain');
        showStatus('Desktop workbench loaded. Exports: ' + Object.keys(workbench).join(', '));

        const authority = webConfig.remoteAuthority || window.location.host;
        const makeUri = (path) => ({ scheme: 'vscode-remote', authority, path });

        const desktopConfig = {
            windowId: 1,
            machineId: 'web-' + (localStorage.getItem('cursor-mid') || (() => { const id = crypto.randomUUID(); localStorage.setItem('cursor-mid', id); return id; })()),
            sqmId: '', devDeviceId: '',
            remoteAuthority: authority,
            appRoot: '/', execPath: '/cursor',
            homeDir: '/home/snekmin',
            tmpDir: '/tmp',
            userDataDir: '/home/snekmin/.cursor',
            backupPath: '',
            isInitialStartup: !localStorage.getItem('cursor-init'),
            fullscreen: false, maximized: false, glass: false,
            colorScheme: { dark: window.matchMedia('(prefers-color-scheme: dark)').matches, highContrast: false },
            autoDetectColorScheme: true, autoDetectHighContrast: true,
            nls: { messages: globalThis._VSCODE_NLS_MESSAGES || [], language: navigator.language?.split('-')[0] || 'en' },
            profiles: {
                home: makeUri('/home/snekmin/.cursor'),
                profile: {
                    id: '__default__', isDefault: true, name: 'Default', icon: undefined,
                    location: makeUri('/home/snekmin/.cursor/profiles'),
                    globalStorageHome: makeUri('/home/snekmin/.cursor/globalStorage'),
                    settingsResource: makeUri('/home/snekmin/.cursor/settings.json'),
                    keybindingsResource: makeUri('/home/snekmin/.cursor/keybindings.json'),
                    tasksResource: makeUri('/home/snekmin/.cursor/tasks.json'),
                    snippetsHome: makeUri('/home/snekmin/.cursor/snippets'),
                    promptsHome: makeUri('/home/snekmin/.cursor/prompts'),
                    extensionsResource: makeUri('/home/snekmin/.cursor/extensions.json'),
                    cacheHome: makeUri('/home/snekmin/.cursor/cache'),
                    useDefaultFlags: undefined, isTransient: false
                },
                all: [{
                    id: '__default__', isDefault: true, name: 'Default', icon: undefined,
                    location: makeUri('/home/snekmin/.cursor/profiles'),
                    globalStorageHome: makeUri('/home/snekmin/.cursor/globalStorage'),
                    settingsResource: makeUri('/home/snekmin/.cursor/settings.json'),
                    keybindingsResource: makeUri('/home/snekmin/.cursor/keybindings.json'),
                    tasksResource: makeUri('/home/snekmin/.cursor/tasks.json'),
                    snippetsHome: makeUri('/home/snekmin/.cursor/snippets'),
                    promptsHome: makeUri('/home/snekmin/.cursor/prompts'),
                    extensionsResource: makeUri('/home/snekmin/.cursor/extensions.json'),
                    cacheHome: makeUri('/home/snekmin/.cursor/cache'),
                    useDefaultFlags: undefined, isTransient: false
                }]
            },
            os: { release: 'web' },
            mainPid: 0, logLevel: 3, loggers: [],
            product: globalThis._VSCODE_PRODUCT_JSON,
            perfMarks: performance.getEntriesByType('mark').map(m => ({
                name: m.name, startTime: Math.round(performance.timeOrigin + m.startTime)
            }))
        };

        localStorage.setItem('cursor-init', '1');
        showStatus('Calling workbench.main()...');
        const result = workbench.main(desktopConfig);
        showStatus('workbench.main() returned: ' + typeof result);
        if (result?.then) {
            result.then(() => showStatus('Promise resolved — workbench started.'))
                  .catch(e => showStatus('Promise rejected: ' + e + '\nStack: ' + (e?.stack || 'none')));
        }
    } catch (err) {
        console.error('[CursorWeb] Boot failed:', err);
        document.body.innerHTML = `
            <div style="padding:40px;font-family:system-ui;color:#ccc;background:#1e1e1e;min-height:100vh">
                <h1 style="color:#fff">Cursor Web — Error</h1>
                <pre style="color:#f88;white-space:pre-wrap;max-width:90vw;overflow:auto">${err.stack || err}</pre>
            </div>`;
    }
}

boot();

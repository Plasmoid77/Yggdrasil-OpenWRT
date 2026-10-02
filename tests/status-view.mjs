// The LuCI view, evaluated the way LuCI does it (the module source as a
// function body) with stub E/_/rpc/ui/window/document: the routed-prefix
// IPv6 cell, the Unknown state of an unprobed row, the protected-host dialog
// and the Unpin dialog that asks again when the backend wants the static
// reservation confirmed. One line before `return view.extend(` hands the
// module's own helpers to the test; nothing else of the source is changed.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const VIEW = fileURLToPath(new URL(
    '../source/yggdrasil-status/www/luci-static/resources/view/status/yggdrasil.js', import.meta.url));

function fail(message) { console.error('FAIL: ' + message); process.exit(1); }
function eq(expected, actual, what) {
    if (expected !== actual) fail(`${what}: expected [${expected}], got [${actual}]`);
}

// --- stub LuCI ---------------------------------------------------------------
// LuCI's String.prototype.format; the paths tested here use %s only.
String.prototype.format = function(...args) {
    let i = 0;
    return this.replace(/%(?:\.\d+)?[a-zA-Z]+/g, () => String(args[i++]));
};

function flat(children) {
    return (Array.isArray(children) ? children : [children])
        .flat(Infinity).filter(c => c != null);
}
function E(tag, attrs, children) {
    if (Array.isArray(attrs) || typeof attrs !== 'object' || attrs === null) {
        children = attrs; attrs = {};
    }
    const el = {
        tag, attrs, children: flat(children), parentNode: null, disabled: 'disabled' in attrs,
        style: { cssText: attrs.style || '', display: /display:\s*none/.test(attrs.style || '') ? 'none' : '' },
        appendChild(child) { this.children.push(child); return child; },
        focus() {},
        get textContent() {
            return this.children.map(c => typeof c === 'object' ? c.textContent : String(c)).join('');
        },
        set textContent(text) { this.children = [String(text)]; }
    };
    return el;
}
const _ = s => s;
function walk(node, test, out = []) {
    if (node && typeof node === 'object') {
        if (test(node)) out.push(node);
        (node.children || []).forEach(c => walk(c, test, out));
    }
    return out;
}
const buttons = (node, label) => walk(node, n => n.tag === 'button' && n.textContent === label);
const click = el => el.attrs.click({ preventDefault() {} });
const settle = () => new Promise(resolve => setImmediate(resolve));

const calls = [];
const replies = {};
const rpc = {
    declare: ({ method }) => (...args) => {
        calls.push({ method, args });
        return Promise.resolve(typeof replies[method] === 'function' ? replies[method](...args) : replies[method]);
    }
};
const modals = [];
let hidden = 0;
const ui = {
    showModal: (title, content) => { modals.push({ title, node: E('div', {}, content) }); },
    hideModal: () => { hidden++; },
    addNotification: () => {}
};
const window = { localStorage: { getItem: () => null, setItem: () => {} } };
const elements = {};
const document = { getElementById: id => elements[id] || null };
const view = { extend: obj => obj };
const uci = { load: () => Promise.resolve(), get: () => null };
const poll = { add: () => {} };

const HOOK = '\nreturn view.extend(';
const source = readFileSync(VIEW, 'utf8');
if (source.split(HOOK).length !== 2) fail('the view no longer ends in exactly one `return view.extend(`');
let helpers;
const hooked = source.replace(HOOK,
    '\n__expose({ ipv6Cell, makeClientTable, persistenceCell, refreshClients });' + HOOK);
const module = new Function('E', '_', 'view', 'rpc', 'uci', 'poll', 'ui', 'window', 'document', '__expose', hooked)(
    E, _, view, rpc, uci, poll, ui, window, document, h => { helpers = h; });
if (!module || typeof module.render !== 'function' || !helpers) fail('the view did not evaluate to a LuCI view');
const { ipv6Cell, makeClientTable, persistenceCell } = helpers;

// --- groups ------------------------------------------------------------------
function ipv6CellGroup() {
    eq('—', ipv6Cell({}), 'no addresses');
    const lines = cell => cell.children.map(c => ({ text: c.textContent, ...c.attrs }));

    // live, canonical address bold wherever it is in the list
    const addrs = ['300:1::a', '300:1::20'];
    let cell = ipv6Cell({ ipv6_addresses: addrs, canonical_ipv6: '300:1::20' });
    eq(null, cell.attrs.title, 'a live cell has no stale title');
    eq(undefined, lines(cell)[0].style, 'a plain live address is not dimmed');
    eq('Canonical address', lines(cell)[1].title, 'canonical title');
    eq('font-weight: 600', lines(cell)[1].style, 'canonical weight');
    eq(2, addrs.length, 'the client list is not modified');

    // DHCPv6: the leased address (first) is the router's record
    cell = ipv6Cell({ ipv6_addresses: ['300:1::20', '300:1:0:0:aa:bb:cc:dd'], ipv6_source: 'dhcpv6', reserved_ipv6: 1,
        ipv6_lease_match: 'neighbor' });
    eq('Assigned by the router (DHCPv6), reserved for this device; matched to this device through the neighbour table',
        lines(cell)[0].title, 'DHCPv6 lease title');
    eq(undefined, lines(cell)[1].title, 'only the leased address is labelled');
    cell = ipv6Cell({ ipv6_addresses: ['300:1::20'], ipv6_source: 'dhcpv6' });
    eq('Assigned by the router (DHCPv6)', lines(cell)[0].title, 'unreserved lease title');

    // not seen on the LAN now: the cell says so and non-canonical lines are dimmed
    cell = ipv6Cell({ ipv6_addresses: ['300:1::a', '300:1::20'], canonical_ipv6: '300:1::20', ipv6_live: 0 });
    if (!/does not see this device/.test(cell.attrs.title || '')) fail('stale cell has no stale title');
    eq('opacity: .55', lines(cell)[0].style, 'stale address dimmed');
    eq('font-weight: 600', lines(cell)[1].style, 'canonical stays bold when stale');
}

function stateGroup() {
    const row = (client, column) => {
        const table = walk(makeClientTable([client]), n => n.tag === 'table')[0];
        const tr = table.children[1];
        return tr.children[column].children[0];
    };
    const base = { hostname: 'laptop', mac: 'aa:bb:cc:dd:ee:ff' };
    eq('Online', row({ ...base, online: true, probed: 1 }, 6).textContent, 'online row');
    const unknown = row({ ...base, online: false, probed: 0 }, 6);
    eq('Unknown', unknown.textContent, 'unprobed row');
    if (!/next refresh/.test(unknown.attrs.title)) fail('Unknown has no explanation');
    eq('Offline', row({ ...base, online: false, probed: 1 }, 6).textContent, 'probed offline row');
    eq('Offline', row({ ...base, online: false }, 6).textContent, 'a row without probed is not Unknown');
}

function protectedGroup() {
    modals.length = 0; calls.length = 0;
    const client = { persistent: true, protected_host: true, shared_host: true, reserved_ipv6: '20', mac: 'aa:bb:cc:dd:ee:ff' };
    const cell = persistenceCell(client);
    eq(0, buttons(cell, 'Unpin').length, 'a protected host offers no Unpin');
    click(buttons(cell, 'Manage')[0]);
    eq(1, modals.length, 'one dialog');
    eq('Manage persistent device', modals[0].title, 'protected dialog title');
    const text = modals[0].node.textContent;
    if (!text.includes('Reason: the config host contains multiple MAC addresses; the device has a DHCPv6 address reservation'))
        fail('reasons missing: ' + text);
    eq(0, buttons(modals[0].node, 'Unpin').length + buttons(modals[0].node, 'Unpin and remove reservation').length,
        'the protected dialog cannot unpin');
    persistenceCell({ persistent: true, protected_host: true }).children[1].attrs.click({ preventDefault() {} });
    if (!modals[1].node.textContent.includes('requires manual review')) fail('no fallback reason');
    eq(0, calls.length, 'no RPC from the protected dialog');
}

async function confirmGroup() {
    modals.length = 0; calls.length = 0; hidden = 0;
    const client = { persistent: true, managed_pin: true, mac: 'aa:bb:cc:dd:ee:ff', hostname: 'laptop' };
    replies.unpin = (mac, confirm) => confirm
        ? { ok: true, code: 'unpinned' }
        : { ok: false, code: 'static_confirmation_required', message: 'This device has DHCP reservations.',
            reserved_ipv4: '192.0.2.10', reserved_ipv6: '300:1::20' };
    replies.clients = { clients: [] };

    click(buttons(persistenceCell(client), 'Unpin')[0]);
    eq('Unpin device', modals[0].title, 'first dialog');
    click(buttons(modals[0].node, 'Unpin')[0]);
    await settle();
    eq('unpin', calls[0].method, 'first call');
    eq(false, calls[0].args[1], 'first Unpin does not confirm');

    // the backend asks for confirmation: the dialog comes back with the reservations
    eq(2, modals.length, 'the dialog is shown again');
    eq(1, hidden, 'the first dialog was closed');
    const again = modals[1].node;
    const text = again.textContent;
    if (!text.includes('This device has DHCP reservations.')) fail('backend message missing: ' + text);
    if (!text.includes('Reserved: 192.0.2.10, 300:1::20')) fail('reservations missing: ' + text);
    eq(0, buttons(again, 'Unpin').length, 'the plain Unpin button is gone');
    click(buttons(again, 'Unpin and remove reservation')[0]);
    await settle();
    eq(true, calls[1].args[1], 'the second Unpin confirms');
    eq('aa:bb:cc:dd:ee:ff', calls[1].args[0], 'same MAC');
    eq(2, hidden, 'the dialog closed after success');
    eq('clients', calls[2] && calls[2].method, 'the table refreshes');

    // the confirmation is remembered on the row until the next refresh
    eq(1, client.static_ipv4, 'the row now asks for the static confirmation');

    // a refusal stays in the dialog with the backend's message
    modals.length = 0; calls.length = 0;
    replies.unpin = { ok: false, code: 'busy', message: 'Another DHCP configuration update is already in progress.' };
    click(buttons(persistenceCell({ persistent: true, managed_pin: true, mac: 'aa:bb:cc:dd:ee:01' }), 'Unpin')[0]);
    const action = buttons(modals[0].node, 'Unpin')[0];
    click(action);
    eq(true, action.disabled, 'the button is disabled while the call runs');
    await settle();
    const box = walk(modals[0].node, n => n.tag === 'div' && /color:#dc2626/.test(n.attrs.style || ''))[0];
    eq('Another DHCP configuration update is already in progress.', box.textContent, 'error shown');
    eq('', box.style.display, 'error box visible');
    eq(false, action.disabled, 'the button is usable again');
    eq(1, modals.length, 'no second dialog on a refusal');
}

async function refreshFailureGroup() {
    const warning = E('div', { style: 'display: none' }, []);
    elements['yggdrasil-clients-refresh-error'] = warning;
    replies.clients = () => Promise.reject(new Error('RPC unavailable'));
    await helpers.refreshClients().catch(() => {});
    eq('', warning.style.display, 'failed refresh warning visible');
    if (!warning.textContent.includes('RPC unavailable')) fail('refresh failure omitted from warning');
    for (const reason of [null, undefined]) {
        replies.clients = () => Promise.reject(reason);
        await helpers.refreshClients();
        eq('', warning.style.display, 'empty rejection still shows a warning');
    }
    replies.clients = [];
    await helpers.refreshClients();
    eq('none', warning.style.display, 'successful refresh clears warning');
    delete elements['yggdrasil-clients-refresh-error'];
}

const groups = [
    ['a failed refresh visibly marks the retained inventory, and recovery clears it', refreshFailureGroup],
    ['the routed-prefix IPv6 cell: canonical, DHCPv6 lease, stale addresses', ipv6CellGroup],
    ['an unprobed row is Unknown, never Offline', stateGroup],
    ['a protected host gets an explanation and no Unpin', protectedGroup],
    ['Unpin asks again with the reservations when the backend wants confirmation', confirmGroup]
];
for (const [name, fn] of groups) {
    await fn();
    console.log('PASS: ' + name);
}
console.log(`${groups.length} view groups passed`);

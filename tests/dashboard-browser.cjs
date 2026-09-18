// Browser API regression test; uses the existing Node installation, no packages.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/../dashboard/www/app.js`, 'utf8');
async function main() {
    const elements = new Map();
    const element = selector => {
        if (!elements.has(selector)) elements.set(selector, {
            textContent: '', hidden: false, value: '', listeners: {},
            addEventListener(event, callback) { this.listeners[event] = callback; },
            replaceChildren() {},
        });
        return elements.get(selector);
    };
    const requests = [];
    let mode = 'unauthorized';
    let releaseOldRequest;
    const context = vm.createContext({
        document: {
            querySelector: element, querySelectorAll: () => [],
            createDocumentFragment() { throw new Error('render-fixture-error'); },
        },
        // These browsers support cancellation but not AbortSignal.timeout().
        AbortSignal: {}, AbortController, setTimeout, clearTimeout,
        setInterval() {},
        fetch: async (url, options) => {
            requests.push({url, options});
            if (mode === 'pending-state') return new Promise(resolve => { releaseOldRequest = resolve; });
            if (mode === 'hang') return new Promise((resolve, reject) => {
                options.signal.addEventListener('abort', () => reject(options.signal.reason));
            });
            if (mode === 'body-hang') return {status: 200, ok: true, json: () => new Promise((resolve, reject) => {
                options.signal.addEventListener('abort', () => reject(options.signal.reason));
            })};
            if (mode === 'lost-session' && url.endsWith('/login.sh')) return {status: 200, ok: true, json: async () => ({ok: true})};
            if (mode === 'render-error') return {
                status: 200, ok: true,
                json: async () => ({ok: true, controller: {running: true}, hosts: [], events: []}),
            };
            return {status: 401, ok: false, json: async () => ({error: 'login_required', reason: 'missing_cookie'})};
        },
    });
    vm.runInContext(source, context);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(requests.length, 1, 'initial state request must reach fetch without AbortSignal.timeout');
    assert.equal(element('#login-message').textContent, '', '401 should show login, not an outage');
    assert.equal(element('#login-screen').hidden, false);
    element('#password').value = 'test-only';
    await element('#login-form').listeners.submit({preventDefault() {}});
    assert.equal(requests.at(-1).url, '/cgi-bin/login.sh');
    assert.match(element('#login-message').textContent, /密码不正确/);
    await element('#logout').listeners.click();
    assert.equal(requests.at(-1).url, '/cgi-bin/logout.sh');
    mode = 'lost-session';
    element('#password').value = 'test-only';
    await element('#login-form').listeners.submit({preventDefault() {}});
    assert.match(element('#login-message').textContent, /Cookie|会话/, 'login followed by 401 must explain the failure');
    assert.equal(requests.at(-1).options.credentials, 'same-origin');
    mode = 'pending-state';
    const oldRefresh = vm.runInContext('refresh()', context);
    mode = 'lost-session';
    const loginDuringRefresh = element('#login-form').listeners.submit({preventDefault() {}});
    await new Promise(resolve => setImmediate(resolve));
    releaseOldRequest({status: 401, ok: false, json: async () => ({reason: 'missing_cookie'})});
    await Promise.all([oldRefresh, loginDuringRefresh]);
    assert.match(element('#login-message').textContent, /Cookie|会话/);
    assert.equal(element('#login-submit').disabled, false, 'pending refresh must not strand the login button');
    mode = 'render-error';
    await element('#login-form').listeners.submit({preventDefault() {}});
    assert.match(element('#login-message').textContent, /render-fixture-error/, 'render errors must remain visible on the login screen');
    mode = 'hang';
    await assert.rejects(vm.runInContext("fetchWithTimeout('/slow', {}, 10)", context), {name: 'AbortError'});
    assert.equal(requests.at(-1).options.signal.aborted, true);
    mode = 'body-hang';
    await assert.rejects(vm.runInContext("fetchWithTimeout('/slow-body', {}, 10)", context), {name: 'AbortError'});
    console.log('PASS: browser compatibility, credentials, login/refresh race, rejected sessions, render errors and full-body timeout');
}
main().catch(error => { console.error(error); process.exitCode = 1; });

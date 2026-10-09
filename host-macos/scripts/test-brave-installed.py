#!/usr/bin/env python3
"""Opt-in signed-host Brave acceptance on a coordinated desktop, no models/accounts.

PI_OS_BRAVE_MODE=ax (default): the host's Accessibility routes (browser.page, browser.axAct) against
a fresh loopback fixture page. No DevTools connection, no dialog; acts run with Brave left where it is.
PI_OS_BRAVE_MODE=cdp: the DevTools opt-in through the production TS adapter (brave-integration-fixture.mjs);
Brave asks for approval on that connection, which this script never automates.

Leaves the user's Brave process and tabs running. Only the fixture tab receives input; its "Delete file"
button only counts and must be refused. Evidence stays in a temp directory without page content.
"""
import json, os, pathlib, plistlib, re, secrets, socket, subprocess, tempfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
if os.environ.get('PI_OS_INSTALLED_TEST') != '1':
    raise SystemExit('Coordinate the desktop, then set PI_OS_INSTALLED_TEST=1.')
ROOT = pathlib.Path(__file__).resolve().parents[2]
MODE = os.environ.get('PI_OS_BRAVE_MODE', 'ax')
if MODE not in ('ax', 'cdp'): raise SystemExit('PI_OS_BRAVE_MODE must be ax or cdp')
credentials_allowed = os.environ.get('PI_OS_TEST_CREDENTIALS') == '1'
APP = pathlib.Path(os.environ.get('PI_OS_TEST_APP', pathlib.Path.home() / 'Applications/pi-os.app')).resolve()
ORCA = os.environ.get('ORCA_CLI_COMMAND') or ('orca-dev' if os.environ.get('ORCA_DEV_REPO_ROOT') else 'orca')
root = pathlib.Path(tempfile.mkdtemp(prefix='pi-os-brave-installed-'))
token = secrets.token_hex(32)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
host_port, node_port = free_port(), free_port()
def request(port, path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if body is None else json.dumps(body).encode(),
        headers={'X-Harness-Token': token, 'Content-Type': 'application/json'})
    with opener.open(req, timeout=15) as r: return json.load(r)
def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for fixture state')
def gui(*args):
    r = subprocess.run([ORCA, 'computer', *args, '--no-screenshot', '--json'], capture_output=True, text=True, timeout=15)
    result = json.loads(r.stdout)
    if not result.get('ok'): raise RuntimeError(result.get('error'))
    return result['result']
def host_pid_at_port():
    r = subprocess.run(['/usr/sbin/lsof', '-t', f'-iTCP:{host_port}', '-sTCP:LISTEN'], capture_output=True, text=True)
    return int(r.stdout.strip()) if r.stdout.strip() else None
def frontmost_bundle():
    # lsappinfo needs no Automation/TCC grant (unlike System Events).
    asn = subprocess.run(['lsappinfo', 'front'], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(['lsappinfo', 'info', '-only', 'bundleid', asn], capture_output=True, text=True).stdout
    match = re.search(r'"CFBundleIdentifier"="([^"]+)"', info)
    return match.group(1) if match else None

# AX-mode fixture: the same harmless page as brave-integration-fixture.mjs (dummy credential canaries,
# a Like counter, an input-event counter, a counting "Delete file" button and a same-tab link).
FIXTURE_PATH = '/pi-os-browser-fixture-' + secrets.token_hex(8)
FIXTURE_HTML = f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>pi-os integrated Brave fixture</title><style>body{{font:18px system-ui;max-width:700px;margin:60px auto;padding:24px}}button,input{{font:inherit;padding:10px;margin:10px}}article{{border:1px solid #ddd;padding:18px}}</style><h1>pi-os integrated Brave fixture</h1><p>Local test only. No accounts or real file operations.</p><label>Test note <input id="note"></label><label>Multiline note <textarea id="multiline"></textarea></label><label>Username <input id="username" autocomplete="username" value="PRIVATE-USERNAME-CANARY"></label><label>Password canary <input type="password" value="PRIVATE-FIXTURE-CANARY"></label><article><h2>Fixture post</h2><button id="like" aria-pressed="false" onclick="this.setAttribute('aria-pressed','true');document.querySelector('#count').textContent=String(Number(document.querySelector('#count').textContent)+1)">Like fixture</button><p>Like clicks: <span id="count">0</span></p><button onclick="document.querySelector('#deleted').textContent='1'">Delete file</button><p>Deletion attempts: <span id="deleted">0</span></p></article><p><a href="{FIXTURE_PATH}?next=1">Next fixture page</a></p><script>document.querySelector('#note').addEventListener('input',()=>document.querySelector('#input').textContent=String(Number(document.querySelector('#input').textContent)+1))</script><p>Input events: <span id="input">0</span></p></html>'''
class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in (FIXTURE_PATH, FIXTURE_PATH + '?next=1'):
            self.send_response(404); self.end_headers(); return
        body = FIXTURE_HTML.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'")
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass

CANARIES = ('PRIVATE-USERNAME-CANARY', 'PRIVATE-FIXTURE-CANARY', 'dummy-credential-QA-only')
def run_ax(context, report, host_pid):
    def check(name, condition):
        if not condition: raise AssertionError(name)
        report['checks'].append(name); print('PASS', name, flush=True)
    def tool(name, arguments):
        return request(host_port, '/tools/' + name, {'arguments': {'contextId': context, **arguments}})
    def page():
        for _ in range(30):
            outcome = tool('browser.page', {})
            if outcome['ok']: return outcome['result']
            if outcome['error']['code'] != 'browser_stale': raise AssertionError(outcome['error']['code'])
            time.sleep(.1)  # Observation-only retries while the fixture navigation completes.
        raise AssertionError('page stayed stale')
    def ref(digest, label):
        for item in digest['links'] + digest['controls'] + digest['fields']:
            if item['label'] == label: return item['ref']
        raise AssertionError('missing fixture ref: ' + label)
    def act(ref_, action, value=None):
        return tool('browser.axAct', {'ref': ref_, 'action': action, **({'value': value} if value is not None else {})})
    def clean(payload): return not any(c in json.dumps(payload) for c in CANARIES)
    snapshot = request(host_port, '/tools/desktop.getContext', {'arguments': {'contextId': context}})['result']
    check('Hotkey pinned the selected Brave tab in Accessibility mode', snapshot.get('browser') == {'name': 'Brave', 'mode': 'ax', 'pinned': True, 'background': True})
    digest = page()
    check('AX digest reads the fixture without a DevTools connection', 'Fixture post' in [h['label'] for h in digest['headings']] and 'Like clicks: 0' in digest['text'])
    secure = {f['label']: f for f in digest['fields'] if f['label'] in ('Username', 'Password canary')}
    check('Credential fields are flagged secure and carry no value', len(secure) == 2 and all(f['secure'] and 'value' not in f for f in secure.values()))
    check('No credential value appears anywhere in the digest', clean(digest))
    for label in ('Username', 'Password canary'):
        outcome = act(ref(digest, label), 'setValue', 'dummy-credential-QA-only' if credentials_allowed else 'MUST-NOT-APPEAR')
        if credentials_allowed: check(label + ' accepts dummy input with the Settings opt-in', outcome['ok'] and clean(outcome))
        else: check(label + ' is blocked by default', not outcome['ok'] and outcome['error']['code'] == 'credential_input_blocked')
        digest = page()
        check(label + ' value stays out of the digest', clean(digest) and 'MUST-NOT-APPEAR' not in json.dumps(digest))
    front = frontmost_bundle()
    like = act(ref(digest, 'Like fixture'), 'press')
    check('Background press is performed once and returns fresh refs', like['ok'] and 'Like clicks: 1' in like['result']['page']['text'])
    check('The press neither raised nor activated another app', frontmost_bundle() == front)
    check('Like is pressed in the fresh digest', any(c['label'] == 'Like fixture' and c.get('pressed') for c in like['result']['page']['controls']))
    stale = act(ref(digest, 'Like fixture'), 'press')
    check('A consumed ref cannot act again', not stale['ok'] and stale['error']['code'] == 'browser_stale')
    digest = page()
    note = act(ref(digest, 'Test note'), 'setValue', 'pi-os integrated — Grüß dich 👋')
    check('setValue is verified by readback and fires an input event', note['ok'] and 'shows the new value' in note['result']['verification'] and 'Input events: 1' in note['result']['page']['text'])
    digest = page()
    multi = act(ref(digest, 'Multiline note'), 'setValue', 'First ü😀\r\n\r\n日本語\rLast\n')
    check('Multiline Unicode/CRLF delivery is verified', multi['ok'])
    digest = page()
    single = act(ref(digest, 'Test note'), 'setValue', 'one\ntwo')
    check('A single-line field refuses a line break before acting', not single['ok'] and single['error']['code'] == 'invalid_arguments')
    digest = page()
    deletion = act(ref(digest, 'Delete file'), 'press')
    check('Recognized Delete control is refused', not deletion['ok'] and deletion['error']['code'] == 'file_deletion_blocked')
    check('The refused Delete control received nothing', 'Deletion attempts: 0' in page()['text'])
    digest = page()
    old_link = ref(digest, 'Next fixture page')
    act(old_link, 'press')
    for _ in range(30):
        digest = page()
        if 'Like clicks: 0' in digest['text'] and (digest.get('url') or '').endswith('?next=1'): break
        time.sleep(.1)
    check('Same-tab navigation keeps the native binding and resets the fixture', 'Like clicks: 0' in digest['text'])
    replay = act(old_link, 'press')
    check('Pre-navigation refs cannot target the new document', not replay['ok'] and replay['error']['code'] == 'browser_stale')
    established = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(host_pid), '-iTCP', '-sTCP:ESTABLISHED'], capture_output=True, text=True).stdout
    check('The host opened no DevTools connection', f":{os.environ.get('PI_OS_BRAVE_PORT', '9222')}" not in established)

host_pid = None
fixture = None
server = None
record = root / 'invocation.json'
try:
    subprocess.run(['codesign', '--verify', '--strict', str(APP)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(APP)], capture_output=True, text=True, check=True)
    assert 'Authority=Apple Development:' in signature.stderr or 'Authority=Developer ID Application:' in signature.stderr
    if MODE == 'cdp':
        log = open(root / 'fixture.log', 'w')
        fixture = subprocess.Popen(['node', '--import', str(ROOT / 'node-harness/test/no-live-models.mjs'), str(ROOT / 'host-macos/scripts/brave-integration-fixture.mjs'), str(root)],
            stdout=log, stderr=log, env={**os.environ, 'PI_OS_INSTALLED_TEST': '1', 'PI_OFFLINE': '1', 'PI_OS_AGENT': '0'})
        wait_for((root / 'fixture-ready.json').exists)
        url = json.loads((root / 'fixture-ready.json').read_text())['url']
    else:
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f'http://127.0.0.1:{server.server_address[1]}{FIXTURE_PATH}'
    assert url.startswith('http://127.0.0.1:')
    subprocess.run(['open', '-a', 'Brave Browser', url], check=True)
    env = {'PI_OS_INSTALLED_TEST': '1', 'PI_OFFLINE': '1', 'PI_OS_AGENT': '0', 'PI_OS_TOKEN': token,
        'PI_OS_HOST_PORT': str(host_port), 'PI_OS_NODE_PORT': str(node_port), 'PI_OS_SUPPORT_DIR': str(root / 'support'),
        'PI_OS_NODE_ENTRY': str(ROOT / 'host-macos/scripts/installed-fixture-harness.mjs'), 'PI_OS_TEST_RECORD_FILE': str(record),
        'PI_OS_NODE_WARM_TTL_SECONDS': '3', 'PI_OS_HOTKEY': 'Ctrl+Option+Cmd+Shift+Space', 'PI_OS_BROWSER_DIAGNOSTICS': '1'}
    cmd = ['open', '-n', '-g', '--stdout', str(root / 'host.log'), '--stderr', str(root / 'host.log')]
    for key, value in env.items(): cmd += ['--env', f'{key}={value}']
    # NSArgumentDomain is specific to this launched test instance; no stored setting changes.
    subprocess.run(cmd + [str(APP), '--args', '-braveAccess', MODE, '-braveBackgroundActions', 'YES', '-braveConnectionPort', '9222',
        '-allowCredentialFieldInput', 'YES' if credentials_allowed else 'NO'], check=True)
    host_pid = wait_for(host_pid_at_port)
    assert request(host_port, '/health')['service'] == 'macos-host'
    state = gui('get-app-state', '--app', 'com.brave.Browser', '--restore-window')
    assert 'pi-os integrated Brave fixture' in state['snapshot']['treeText']
    gui('hotkey', '--app', 'com.brave.Browser', '--key', 'CmdOrCtrl+Ctrl+Alt+Shift+Space')
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'Validate only the local browser fixture. No model calls.')
    state = gui('get-app-state', '--app', f'pid:{host_pid}')
    ask = re.search(r'^\s*(\d+) button Ask\b', state['snapshot']['treeText'], re.M)
    assert ask
    gui('click', '--app', f'pid:{host_pid}', '--element-index', ask.group(1))
    wait_for(record.exists)
    context = json.loads(record.read_text())['contextId']
    if MODE == 'cdp':
        (root / 'fixture-context.json').write_text(json.dumps({'hostURL': f'http://127.0.0.1:{host_port}', 'token': token,
            'contextId': context, 'capturesDir': str(root / 'support/captures'), 'credentialsAllowed': credentials_allowed}))
        os.chmod(root / 'fixture-context.json', 0o600)
        fixture.wait(timeout=90)
        report = json.loads((root / 'browser-report.json').read_text())
    else:
        report = {'checks': [], 'modelCalls': 0, 'accountActions': 0, 'fixtureOnly': True, 'mode': 'ax'}
        try:
            run_ax(context, report, host_pid); report['passed'] = True
        except Exception as error:
            report['passed'] = False; report['error'] = type(error).__name__ + ': ' + str(error)
    report['credentialsAllowed'] = credentials_allowed
    report['appUnderTest'] = str(APP)
    report['bundleVersion'] = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
    (root / 'browser-report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    request(node_port, '/fixture/finish', {})
    assert report['passed']
finally:
    print('Evidence:', root, flush=True)
    if host_pid:
        code = f'import AppKit; if let app = NSRunningApplication(processIdentifier: {host_pid}), app.executableURL?.path == {json.dumps(str(APP / "Contents/MacOS/pi-os"))} {{ _ = app.terminate() }}'
        subprocess.run(['swift', '-e', code], timeout=15)
        # Termination is asynchronous; do not race the next fixture's Carbon hotkey.
        for _ in range(60):
            alive = subprocess.run(['ps', '-p', str(host_pid), '-o', 'comm='], capture_output=True, text=True)
            if alive.stdout.strip() != str(APP / 'Contents/MacOS/pi-os'): break
            time.sleep(.1)
    if server: server.shutdown(); server.server_close()
    if fixture and fixture.poll() is None:
        fixture.terminate()
        try: fixture.wait(timeout=3)
        except subprocess.TimeoutExpired: fixture.kill(); fixture.wait(timeout=3)

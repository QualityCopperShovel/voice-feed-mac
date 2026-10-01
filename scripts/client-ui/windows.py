"""Install the published EXE and drive its actual WinForms/WebView2 UI.
The dead startup proxy prevents network access until read-only interception is
installed. No login credentials, write API or testing hook is used.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import urllib.error
import urllib.request
import winreg

from playwright.sync_api import sync_playwright
from pywinauto import Application

OUT = Path('evidence')
OUT.mkdir(exist_ok=True)
report = {'status': 'running', 'checks': [], 'physical_device': False}


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read()


def intercept(route):
    request = route.request
    if request.method not in ('GET', 'HEAD', 'OPTIONS'):
        route.fulfill(status=403, content_type='text/plain', body='Read-only client UI test')
        return
    if '/__client_ui_fixture' in request.url:
        route.fulfill(status=200, content_type='text/html', body='''<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>FairyStack UI fixture</title>
<style>:root{background:#edf7f1;color:#17211c}body{font:20px system-ui;padding:32px}
@media(prefers-color-scheme:dark){:root{background:#141c18;color:#e6efe9}}
input{background:inherit;color:inherit;font:inherit}a{color:inherit}</style>
<p id="selectable">Selectable draft and keyboard fixture</p>
<label>Draft <input id="draft"></label>
<p><a id="external" href="https://example.com/">Open external page</a></p>''')
        return
    headers = {k: v for k, v in request.headers.items() if k.lower() in ('user-agent', 'accept', 'accept-language', 'origin')}
    try:
        req = urllib.request.Request(request.url, headers=headers, method=request.method)
        try:
            response = urllib.request.urlopen(req, timeout=15)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            body = response.read()
            h = {k: v for k, v in response.headers.items() if k.lower() not in ('content-length', 'transfer-encoding', 'content-encoding', 'connection')}
            route.fulfill(status=response.code, headers=h, body=body)
    except Exception as e:
        route.fulfill(status=502, content_type='text/plain', body=str(e))


def main():
    browser = None
    window = None
    try:
        meta = json.loads(get('https://fairystack.com/assets/windows-version.json'))
        data = get(meta['download_url'])
        assert hashlib.sha256(data).hexdigest() == meta['download_sha256']
        (OUT/'release.json').write_text(json.dumps(meta, indent=2))
        setup = Path(os.environ['RUNNER_TEMP'])/'FairyStack-Setup.exe'
        setup.write_bytes(data)
        settings = Path(os.environ['LOCALAPPDATA'])/'FairyStack'
        settings.mkdir(exist_ok=True)
        (settings/'settings.json').write_text(json.dumps({'origin': 'https://multi.fairystack.com/', 'window_open': True}))
        os.environ['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = '--remote-debugging-port=9222 --proxy-server=127.0.0.1:9 --proxy-bypass-list=<-loopback>'
        # Install with no saved window. The first WebView2 process is then owned
        # by the direct installed-client launch, with the test environment.
        (settings/'settings.json').write_text(json.dumps({'origin': 'https://multi.fairystack.com/', 'window_open': False}))
        process = subprocess.Popen([str(setup)], env=os.environ.copy())
        assert process.wait(timeout=60) == 0
        installed = Path(os.environ['LOCALAPPDATA'])/'Programs/FairyStack/FairyStack.exe'
        assert hashlib.sha256(installed.read_bytes()).hexdigest() == meta['download_sha256']
        # Shell installation can relaunch through Explorer's environment. Launch
        # the installed binary directly; registry policy also covers WebView2's
        # inherited startup environment without changing shipped client code.
        subprocess.run(['taskkill', '/T', '/F', '/IM', 'FairyStack.exe'], timeout=15, capture_output=True)
        time.sleep(2)
        shutil.rmtree(settings/'WebView2', ignore_errors=True)
        (settings/'settings.json').write_text(json.dumps({'origin': 'https://multi.fairystack.com/', 'window_open': True}))
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments') as key:
            winreg.SetValueEx(key, '*', 0, winreg.REG_SZ, os.environ['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'])
        subprocess.Popen([str(installed)], env=os.environ.copy())
        app = Application(backend='win32').connect(path=str(installed), timeout=30)
        window = app.top_window()
        window.wait('visible', timeout=30)
        window.set_focus()
        report['checks'].append('Published checksummed installer opened its real native window')
        with sync_playwright() as p:
            end = time.monotonic()+30
            while time.monotonic() < end:
                try:
                    get('http://127.0.0.1:9222/json/version')
                    break
                except Exception:
                    time.sleep(.3)
            else:
                diagnostics = subprocess.run(['powershell', '-NoProfile', '-Command', "Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'FairyStack|msedgewebview2' } | Select-Object Name,ProcessId,ParentProcessId,CommandLine | ConvertTo-Json -Depth 3"], capture_output=True, text=True, timeout=20)
                (OUT/'processes.json').write_text(diagnostics.stdout)
                (OUT/'netstat.txt').write_text(subprocess.check_output(['netstat','-ano'], text=True, timeout=15))
                raise TimeoutError('Installed WebView2 did not expose its debug endpoint within 30 seconds')
            browser = p.chromium.connect_over_cdp('http://127.0.0.1:9222', timeout=10000)
            context = browser.contexts[0]
            context.route('**/*', intercept)
            page = context.pages[0]
            page.set_default_timeout(15000)
            page.set_default_navigation_timeout(45000)
            page.goto('https://multi.fairystack.com/workspace/', wait_until='domcontentloaded')
            page.locator('body').wait_for()
            page.wait_for_function("document.body.innerText.includes('FairyStack')")
            page.screenshot(path=str(OUT/'windows-live.png'))
            window.capture_as_image().save(OUT/'windows-native-light.png')
            report['checks'].append('Real public workspace rendered inside installed WebView2, with all writes blocked')
            page.goto('https://multi.fairystack.com/__client_ui_fixture')
            box = page.locator('#draft').bounding_box()
            page.mouse.click(box['x']+box['width']/2, box['y']+box['height']/2)
            # Actual Windows keyboard input enters the embedded browser.
            window.type_keys('A draft entered through Windows', with_spaces=True, pause=.03)
            assert page.locator('#draft').input_value() == 'A draft entered through Windows'
            window.type_keys('^a^c', pause=.1)
            assert page.locator('#draft').input_value() == 'A draft entered through Windows'
            report['checks'].append('Native keyboard focus and typing reached the embedded draft input')
            window.move_window(width=540, height=620)
            time.sleep(.5)
            assert page.locator('#draft').input_value() == 'A draft entered through Windows'
            window.capture_as_image().save(OUT/'windows-small.png')
            report['checks'].append('Resizing the native window retained the draft')
            page.emulate_media(color_scheme='dark')
            window.capture_as_image().save(OUT/'windows-native-dark.png')
            report['checks'].append('Light and dark rendered screenshots captured')
            report['runtime'] = browser.version
            report['version'] = meta['version']
            report['limitations'] = 'No human sign-in, microphone recording, SmartScreen or Parallels/ARM compatibility exercised.'
            report['status'] = 'completed'
            browser.close()
        window.close()
    except BaseException as e:
        report.update(status='failed', error=str(e))
        if window:
            try:
                window.capture_as_image().save(OUT/'windows-failure.png')
            except Exception:
                pass
        raise
    finally:
        (OUT/'windows.json').write_text(json.dumps(report, indent=2))
        subprocess.run(['taskkill', '/F', '/IM', 'FairyStack.exe'], timeout=15, capture_output=True)


if __name__ == '__main__':
    main()

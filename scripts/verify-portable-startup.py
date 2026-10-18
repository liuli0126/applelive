"""Exercise shipped GUI entries with real OBS and an isolated Windows profile.
Does not touch the running user's OBS, phone, or public ports.
"""
from pathlib import Path
import argparse, base64, ctypes, ctypes.wintypes as wt, json, os, shutil, socket, subprocess, sys, time
import psutil
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'desktop_sender'))
from obs_websocket import OBSClient

def wait_for(fn, seconds=45):
    end = time.monotonic() + seconds
    last = None
    while time.monotonic() < end:
        try:
            result = fn()
            if result: return result
        except (OSError, ValueError, RuntimeError) as e: last=e
        time.sleep(.25)
    raise AssertionError(f'Timed out: {last}')

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));return s.getsockname()[1]

def main():
    import urllib.request
    parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);args=parser.parse_args()
    test=ROOT/'.build/fuxing-entry-test'
    target=test/'换电脑与目录'/('福煋 OBS '+str(int(time.time())))
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(args.source,target)
    plugin=target/'data/obs-plugins/AppleLive'
    config=target/'config/obs-studio'
    env=os.environ.copy()
    env.update(APPDATA=str(test/'fresh-roaming'),LOCALAPPDATA=str(test/'fresh-local'))
    for key in ['APPDATA','LOCALAPPDATA']:Path(env[key]).mkdir(exist_ok=True)
    env['PATH']=str(Path(os.environ['SystemRoot'])/'System32')
    ports={key:free_port() for key in ['DOCK','WEBSOCKET','CONTROL','RELAY']}
    assert len(set(ports.values()))==4
    env.update({f'APPLELIVE_TEST_{k}_PORT':str(v) for k,v in ports.items()})
    host=target/'bin/64bit/AppleLiveOBS.exe'
    def process():
        for p in psutil.process_iter(['pid','exe']):
            if p.info['exe'] and Path(p.info['exe'])==host:return p
    def status():
        with urllib.request.urlopen(f"http://127.0.0.1:{ports['DOCK']}/api/status",timeout=5) as r: return json.load(r)
    def ready():
        value=status()
        return value if value.get('ready') and value['usb'].get('ready') else None
    user=ctypes.WinDLL('user32',use_last_error=True)
    callback=ctypes.WINFUNCTYPE(wt.BOOL,wt.HWND,wt.LPARAM)
    def windows(pid):
        found=[]
        @callback
        def visit(hwnd,_):
            owner=wt.DWORD();user.GetWindowThreadProcessId(hwnd,ctypes.byref(owner))
            if owner.value==pid and user.IsWindowVisible(hwnd):
                buf=ctypes.create_unicode_buffer(512);user.GetWindowTextW(hwnd,buf,512)
                found.append((hwnd,buf.value))
            return True
        user.EnumWindows(visit,0);return found
    def close(p):
        for hwnd,title in windows(p.pid):user.PostMessageW(hwnd,0x10,0,0)
        p.wait(timeout=20)
        wait_for(lambda:not any(x.info['exe'] and str(target).lower() in x.info['exe'].lower()
                 for x in psutil.process_iter(['exe'])),20)
    running=None
    try:
        # Actual EXE, not a direct updater/helper invocation.
        launcher=subprocess.Popen([str(target/'福煋OBS.exe'),'--multi','--disable-shutdown-check'],cwd=test,env=env)
        value=wait_for(ready);running=wait_for(process)
        assert value['desktop_version']=='0.4.5'
        assert value['usb']['native_available']
        with urllib.request.urlopen(f"http://127.0.0.1:{ports['DOCK']}/brand.png",timeout=5) as response:
            assert response.read()==(ROOT/'assets/brand/fuxing.png').read_bytes()
        with urllib.request.urlopen(f"http://127.0.0.1:{ports['DOCK']}/api/phone-plugin",timeout=5) as response:
            assert 'filename*=UTF-8' in response.headers['Content-Disposition']
            assert response.read()==(plugin/'phone-plugin/AppleLive.dylib').read_bytes()

        assert value['bridge']['stream_active'] is False
        assert launcher.poll() is None
        with OBSClient(plugin) as client:
            assert client.request('GetStreamStatus')['outputActive'] is False
            assert client.request('GetRecordStatus')['outputActive'] is False
            client.request('CreateScene',{'sceneName':'保留客户场景'})
        print('PASS fresh EXE: authenticated WebSocket, live dock, native ready, streaming off',flush=True)
        print('WINDOWS',windows(running.pid),flush=True)
        # Repeat entry must focus the existing process and preserve live state.
        again=subprocess.run([str(target/'福煋OBS.exe'),'--multi'],cwd=test,env=env,timeout=10)
        assert again.returncode==0 and process().pid==running.pid
        print('PASS repeat click keeps the same OBS process',flush=True)
        (test/'active-test.json').write_text(json.dumps({'pid':running.pid,'target':str(target),'ports':ports},ensure_ascii=False),encoding='utf-8')
        # Let the embedded browser finish its first polling response, then capture only this window.
        time.sleep(3)
        from PIL import Image
        gdi=ctypes.WinDLL('gdi32');gdi.CreateCompatibleDC.restype=wt.HDC;gdi.CreateCompatibleBitmap.restype=wt.HBITMAP
        user.GetWindowDC.restype=wt.HDC
        user.GetWindowDC.argtypes=[wt.HWND]
        user.ReleaseDC.argtypes=[wt.HWND,wt.HDC]
        user.PrintWindow.argtypes=[wt.HWND,wt.HDC,wt.UINT]
        gdi.CreateCompatibleDC.argtypes=[wt.HDC]
        gdi.CreateCompatibleBitmap.argtypes=[wt.HDC,ctypes.c_int,ctypes.c_int]
        gdi.DeleteObject.argtypes=[wt.HGDIOBJ]
        gdi.DeleteDC.argtypes=[wt.HDC]
        for hwnd,title in windows(running.pid):
            rect=wt.RECT();user.GetWindowRect(hwnd,ctypes.byref(rect));w,h=rect.right-rect.left,rect.bottom-rect.top
            if w<600 or h<400:continue
            dc=user.GetWindowDC(hwnd);memory=gdi.CreateCompatibleDC(dc);bitmap=gdi.CreateCompatibleBitmap(dc,w,h)
            gdi.SelectObject.argtypes=[wt.HDC,wt.HGDIOBJ];gdi.SelectObject.restype=wt.HGDIOBJ
            old=gdi.SelectObject(memory,bitmap)
            user.PrintWindow(hwnd,memory,2)
            class Header(ctypes.Structure):_fields_=[('size',wt.DWORD),('width',wt.LONG),('height',wt.LONG),('planes',wt.WORD),('bits',wt.WORD),('compression',wt.DWORD),('imagesize',wt.DWORD),('x',wt.LONG),('y',wt.LONG),('used',wt.DWORD),('important',wt.DWORD)]
            header=Header(40,w,-h,1,32,0,0,0,0,0,0);buf=ctypes.create_string_buffer(w*h*4)
            gdi.GetDIBits.argtypes=[wt.HDC,wt.HBITMAP,wt.UINT,wt.UINT,ctypes.c_void_p,ctypes.c_void_p,wt.UINT]
            gdi.GetDIBits(memory,bitmap,0,h,buf,ctypes.byref(header),0)
            Image.frombuffer('RGB',(w,h),buf,'raw','BGRX',0,1).save(test/'first-start.png')
            gdi.SelectObject(memory,old);gdi.DeleteObject(bitmap);gdi.DeleteDC(memory);user.ReleaseDC(hwnd,dc)
            break
        close(running);running=None
        assert launcher.wait(timeout=5)==0
        # Simulate a customer moving the package and removing the three manual
        # settings, while retaining a real customer scene.
        scene_path=config/'basic/scenes/AppleLive.json'
        scene=json.loads(scene_path.read_text(encoding='utf-8-sig'));scene['modules']['scripts-tool']=[]
        scene_path.write_text(json.dumps(scene,ensure_ascii=False),encoding='utf-8')
        ws_path=config/'plugin_config/obs-websocket/config.json';ws=json.loads(ws_path.read_text(encoding='utf-8-sig'))
        ws['server_enabled']=False;ws_path.write_text(json.dumps(ws),encoding='utf-8')
        ini=config/'global.ini';text=ini.read_text(encoding='utf-8-sig')
        text='\n'.join(line for line in text.splitlines() if not line.startswith(('ExtraBrowserDocks=','DockState=')))+'\n';ini.write_text(text,encoding='utf-8')
        launcher=subprocess.Popen([str(target/'bin/64bit/obs64.exe'),'--multi','--disable-shutdown-check'],cwd=test,env=env)
        wait_for(ready);running=wait_for(process);assert launcher.poll() is None
        with OBSClient(plugin) as client:
            assert '保留客户场景' in [s['sceneName'] for s in client.request('GetSceneList')['scenes']]
        print('PASS original OBS entry repairs script/WebSocket/dock and preserves customer scene',flush=True)
        close(running);running=None
        assert launcher.wait(timeout=5)==0
        scene=json.loads(scene_path.read_text(encoding='utf-8-sig'))
        scripts=scene['modules']['scripts-tool'];ours=[x for x in scripts if Path(x['path']).name=='AppleLive.lua']
        assert len(ours)==1 and Path(ours[0]['path'])==plugin/'AppleLive.lua'
        print('PASS persisted script path uses relocated customer folder, one registration',flush=True)
        (test/'result.json').write_text(json.dumps({'passed':True,'target':str(target),'ports':ports},ensure_ascii=False),encoding='utf-8')
    finally:
        if running and running.is_running():close(running)
if __name__=='__main__':main()
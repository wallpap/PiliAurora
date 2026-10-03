# 本地实验诊断器；仅断点自己创建的测试进程，不改变系统 WER 或共享文件。
import argparse, ctypes as c, json, os, subprocess, time
from ctypes import wintypes as w
from pathlib import Path

k = c.WinDLL('kernel32', use_last_error=True)
class ExceptionRecord(c.Structure):
    _fields_ = [('code', w.DWORD), ('flags', w.DWORD), ('record', c.c_void_p), ('address', c.c_void_p), ('count', w.DWORD), ('info', c.c_size_t * 15)]
class ExceptionInfo(c.Structure):
    _fields_ = [('record', ExceptionRecord), ('firstChance', w.DWORD)]
class CreateInfo(c.Structure):
    _fields_ = [('file', w.HANDLE), ('process', w.HANDLE), ('thread', w.HANDLE), ('base', c.c_void_p), ('debugOffset', w.DWORD), ('debugSize', w.DWORD), ('tls', c.c_void_p), ('start', c.c_void_p), ('imageName', c.c_void_p), ('unicode', w.WORD)]
class DllInfo(c.Structure):
    _fields_ = [('file', w.HANDLE), ('base', c.c_void_p), ('debugOffset', w.DWORD), ('debugSize', w.DWORD), ('imageName', c.c_void_p), ('unicode', w.WORD)]
class Union(c.Union):
    _fields_ = [('exception', ExceptionInfo), ('create', CreateInfo), ('dll', DllInfo), ('exitCode', w.DWORD), ('padding', c.c_byte * 160)]
class Event(c.Structure):
    _fields_ = [('kind', w.DWORD), ('pid', w.DWORD), ('tid', w.DWORD), ('value', Union)]
for name, argtypes, restype in [
    ('WaitForDebugEvent', [c.POINTER(Event), w.DWORD], w.BOOL),
    ('ContinueDebugEvent', [w.DWORD,w.DWORD,w.DWORD], w.BOOL),
    ('ReadProcessMemory', [w.HANDLE,c.c_void_p,c.c_void_p,c.c_size_t,c.POINTER(c.c_size_t)], w.BOOL),
    ('WriteProcessMemory', [w.HANDLE,c.c_void_p,c.c_void_p,c.c_size_t,c.POINTER(c.c_size_t)], w.BOOL),
    ('FlushInstructionCache', [w.HANDLE,c.c_void_p,c.c_size_t], w.BOOL),
    ('GetFinalPathNameByHandleW', [w.HANDLE,w.LPWSTR,w.DWORD,w.DWORD], w.DWORD),
    ('CloseHandle', [w.HANDLE], w.BOOL),
    ('SetErrorMode', [w.UINT], w.UINT),
    ('GetProcAddress', [w.HMODULE,c.c_char_p], c.c_void_p),
    ('OpenThread', [w.DWORD,w.BOOL,w.DWORD], w.HANDLE),
    ('GetThreadContext', [w.HANDLE,c.c_void_p], w.BOOL),
]:
    fn=getattr(k,name);fn.argtypes=argtypes;fn.restype=restype
parser=argparse.ArgumentParser()
parser.add_argument('--exe', required=True)
parser.add_argument('--profile', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--mode', default='scope-destroy')
parser.add_argument('--webview', action='store_true')
parser.add_argument('--native-runner', action='store_true')
parser.add_argument('--app-arg', action='append', default=[])
parser.add_argument('--close-after-seconds', type=float)
parser.add_argument('--close-after-marker')
a=parser.parse_args()
if os.name != 'nt' or c.sizeof(c.c_void_p) != 8:
    parser.error('The guarded debugger requires 64-bit Windows Python')
if a.native_runner and not (a.close_after_seconds is not None or a.close_after_marker):
    parser.error('Native runner requires a close condition')
folder=Path(a.output).resolve()
folder.mkdir(parents=True,exist_ok=False)
exe=Path(a.exe).resolve();profile=Path(a.profile).resolve()
args=[str(exe),'guard-selftest'] if a.mode=='guard-selftest' else [str(exe),str(profile/'data'),a.mode]+(['--webview'] if a.webview else [])
if a.native_runner:
    args=[str(exe)]+a.app_arg
modules={};traps={};events=[];guard_ready=False;failure=None;process_exit=None
close_requested=False;marker_seen=False
u=c.WinDLL('user32',use_last_error=True)
EnumCallback=c.WINFUNCTYPE(w.BOOL,w.HWND,w.LPARAM)
u.EnumWindows.argtypes=[EnumCallback,w.LPARAM];u.EnumWindows.restype=w.BOOL
u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)];u.GetWindowThreadProcessId.restype=w.DWORD
u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int];u.GetClassNameW.restype=c.c_int
u.PostMessageW.argtypes=[w.HWND,w.UINT,w.WPARAM,w.LPARAM];u.PostMessageW.restype=w.BOOL

def close_own_window():
    found=[]
    @EnumCallback
    def visit(hwnd, _):
        pid=w.DWORD();u.GetWindowThreadProcessId(hwnd,c.byref(pid))
        if pid.value==p.pid:
            name=c.create_unicode_buffer(128)
            u.GetClassNameW(hwnd,name,len(name))
            if name.value=='FLUTTER_RUNNER_WIN32_WINDOW':found.append(hwnd)
        return True
    u.EnumWindows(visit,0)
    return bool(found and u.PostMessageW(found[0],0x0010,0,0))

local_dlls={name:c.WinDLL(name) for name in ['ntdll.dll','kernelbase.dll']}
exports={'ntdll.dll':['NtRaiseHardError'],'kernelbase.dll':['RaiseFailFastException']}

def read(address,size):
    if not address:return b''
    buf=c.create_string_buffer(size);got=c.c_size_t()
    if not k.ReadProcessMemory(w.HANDLE(int(p._handle)),address,buf,size,c.byref(got)):return b''
    return buf.raw[:got.value]

def module(address):
    for base,(name,size) in modules.items():
        if base<=address<base+size:return name+'+'+hex(address-base)
    return hex(address)

def load_module(base,handle):
    name='<unknown>';buf=c.create_unicode_buffer(32768)
    if handle:
        if k.GetFinalPathNameByHandleW(handle,buf,len(buf),0):name=Path(buf.value).name.lower()
        k.CloseHandle(handle)
    header=read(base,64)
    offset=int.from_bytes(header[60:64],'little') if len(header)==64 else 0
    pe=read(base+offset,84) if offset else b''
    size=int.from_bytes(pe[80:84],'little') if len(pe)==84 else 0
    modules[base]=(name,size)
    if name in exports:
        local=local_dlls[name]
        for export in exports[name]:
            addr=k.GetProcAddress(w.HMODULE(local._handle),export.encode())
            if not addr:continue
            remote=base+addr-local._handle
            byte=c.create_string_buffer(b'\xcc',1);written=c.c_size_t()
            if k.WriteProcessMemory(w.HANDLE(int(p._handle)),remote,byte,1,c.byref(written)) and written.value==1:
                k.FlushInstructionCache(w.HANDLE(int(p._handle)),remote,1)
                traps[remote]=export
                events.append('GUARD_INSTALLED '+name+'!'+export)
            else:raise OSError(c.get_last_error(),'Could not install process-local guard')

def trace(tid):
    raw=c.create_string_buffer(1250);address=(c.addressof(raw)+15)&~15
    c.c_uint32.from_address(address+48).value=0x100003
    thread=k.OpenThread(0x0008,False,tid)
    if not thread:return {}
    try:
        if not k.GetThreadContext(thread,address):return {}
        rcx=c.c_uint64.from_address(address+128).value
        rsp=c.c_uint64.from_address(address+152).value
        data=read(rsp,8*96)
        stack=[module(int.from_bytes(data[n:n+8],'little')) for n in range(0,len(data),8)]
        stack=[item for item in stack if '+' in item]
        return {'rcx':rcx,'stackCandidates':stack}
    finally:k.CloseHandle(thread)

previous=k.SetErrorMode(0x0001|0x0002|0x8000)
try:
    env=os.environ.copy();env['PATH']=str(profile)+';'+env['PATH']
    with (folder/'stdout.log').open('wb') as out,(folder/'stderr.log').open('wb') as err:
        p=subprocess.Popen(args,cwd=profile,env=env,stdout=out,stderr=err,creationflags=0x00000002|0x08000000)
        k.SetErrorMode(previous)
        started=time.monotonic();deadline=started+90
        try:
            while time.monotonic()<deadline:
                if a.native_runner and guard_ready and not close_requested:
                    if a.close_after_marker:
                        marker_seen=a.close_after_marker.encode() in (folder/'stdout.log').read_bytes()
                    elapsed_ready=a.close_after_seconds is not None and time.monotonic()-started>=a.close_after_seconds
                    if marker_seen or elapsed_ready:
                        close_requested=close_own_window()
                        if close_requested:events.append('OWN_WINDOW_CLOSE_REQUESTED')
                event=Event()
                if not k.WaitForDebugEvent(c.byref(event),250):continue
                status=0x00010002
                if event.kind==3:
                    load_module(event.value.create.base,event.value.create.file)
                    k.CloseHandle(event.value.create.thread);k.CloseHandle(event.value.create.process)
                elif event.kind==6:load_module(event.value.dll.base,event.value.dll.file)
                elif event.kind==7:modules.pop(event.value.dll.base,None)
                elif event.kind==1:
                    info=event.value.exception;code=info.record.code;addr=info.record.address
                    if code==0x80000003 and addr in traps:
                        details=trace(event.tid);name=traps[addr]
                        arg=details.get('rcx',0)
                        fatal=int.from_bytes(read(arg,4),'little') if name=='RaiseFailFastException' else arg&0xffffffff
                        failure={'kind':'guard-intercept','function':name,'code':hex(fatal),**details}
                        events.append('INTERCEPT '+name+' code='+hex(fatal))
                        p.kill()
                    elif code==0x80000003:
                        if len(traps)<2:
                            failure={'kind':'guard-not-ready'};p.kill()
                        else:
                            guard_ready=True;events.append('GUARD_READY')
                    elif code not in (0x80000004,0x406d1388):
                        status=0x80010001
                        if not info.firstChance:
                            failure={'kind':'unhandled-exception','code':hex(code),'at':module(addr),**trace(event.tid)}
                            p.kill()
                elif event.kind==5:
                    process_exit=event.value.exitCode
                k.ContinueDebugEvent(event.pid,event.tid,status)
                if event.kind==5:break
            else:
                failure={'kind':'timeout'};p.kill()
            p.wait(timeout=5)
        finally:
            if p.poll() is None:p.kill();p.wait(timeout=5)
finally:k.SetErrorMode(previous)
if a.native_runner and not close_requested and failure is None:
    failure={'kind':'close-not-requested'}
if a.close_after_marker and not marker_seen and failure is None:
    failure={'kind':'ready-marker-missing'}
result={'closeRequested':close_requested,'markerSeen':marker_seen,'guardReady':guard_ready,'failure':failure,'processExit':hex(process_exit) if process_exit is not None else None,'debuggerInterceptedFailure':failure is not None,'webview':a.webview,'mode':'native-runner' if a.native_runner else a.mode}
(folder/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
(folder/'events.log').write_text('\n'.join(events)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='failure'}))
if failure:print(json.dumps({k:v for k,v in failure.items() if k not in ('rcx','stackCandidates')}))
raise SystemExit(0 if guard_ready and failure is None and process_exit==0 else 1)

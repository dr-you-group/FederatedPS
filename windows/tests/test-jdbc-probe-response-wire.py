# Loopback TDS fault fixture; never connects to a clinical database.
# Run from the repo with FPS_TEST_R and FPS_TEST_JDBC pointing to R and the pinned driver.
import socket,struct,threading,subprocess,time,tempfile,os
from pathlib import Path
ROOT=Path(__file__).resolve().parent; REPO=ROOT.parents[1]
R=Path(os.environ.get('FPS_TEST_R','R'))
JAR=Path(os.environ['FPS_TEST_JDBC']).resolve()
assert JAR.is_file(), 'Set FPS_TEST_JDBC to a Microsoft mssql-jdbc JAR'
def exact(c,n):
 b=b''
 while len(b)<n:
  d=c.recv(n-len(b))
  if not d: raise EOFError()
  b+=d
 return b
def read(c):
 data=b''
 while True:
  h=exact(c,8);typ,status,n,spid,pid,win=struct.unpack('!BBHHBB',h);data+=exact(c,n-8)
  if status&1:return typ,data
def send(c,b,end=True):c.sendall(struct.pack('!BBHHBB',4,int(end),len(b)+8,0,1,0)+b)
def done(status=0,rows=0):return b'\xfd'+struct.pack('<HHQ',status,0,rows)
def col(name,string=False):
 t=b'\xe7'+struct.pack('<H',1024)+bytes.fromhex('0904d00034') if string else b'\x38'
 return struct.pack('<IH',0,0)+t+bytes([len(name)])+name.encode('utf-16le')
def error():
 msg='Fixture late SQL failure';server='Fixture';proc=''
 b=struct.pack('<IBBH',50000,1,16,len(msg))+msg.encode('utf-16le')+bytes([len(server)])+server.encode('utf-16le')+b'\x00'+struct.pack('<I',1)
 return b'\xaa'+struct.pack('<H',len(b))+b

def run(mode,case,rows=1):
 sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen(1);port=sock.getsockname()[1]
 events=[];errors=[]
 def serve():
  try:
   c,_=sock.accept();c.settimeout(8)
   with c:
    typ,_=read(c);assert typ==18
    send(c,b'\x00\x00\x0b\x00\x06\x01\x00\x11\x00\x01\xff'+b'\x0f\x00\x07\xd0\x00\x00\x02')
    typ,_=read(c);assert typ==16
    ack=b'\x01'+bytes.fromhex('74000004')+bytes([7])+'Fixture'.encode('utf-16le')+bytes([15,0,7,208])
    send(c,b'\xad'+struct.pack('<H',len(ack))+ack+done())
    while True:
     typ,data=read(c)
     if typ!=1:events.append('packet:'+str(typ));continue
     n=struct.unpack('<I',data[:4])[0];sql=data[n:].decode('utf-16le');events.append(sql)
     if not sql.startswith('SELECT TOP (2)'):send(c,done());continue
     name='Synthetic 강남'.encode('utf-16le')
     response=b'\x81\x03\x00'+col('care_site_id')+col('care_site_name',True)+col('care_site_source_value',True)
     response+=(b'\xd1'+struct.pack('<iH',2,len(name))+name+b'\xff\xff')*rows
     if case=='late-error':
      send(c,response+done(1|0x10,rows),False)
      time.sleep(.15);send(c,error()+done(2))
     elif case=='missing-terminal':
      send(c,response+done(1|0x10,rows),False)
      # A complete rowset, but no final batch response. Ignore ATTENTION.
     else:
      send(c,response,False);time.sleep(.1);send(c,done(0x10,rows))
  except (EOFError,ConnectionResetError,BrokenPipeError):pass
  except Exception as e:errors.append(repr(e))
  finally:sock.close()
 t=threading.Thread(target=serve,daemon=True);t.start()
 with tempfile.TemporaryDirectory() as out:
  p=subprocess.run([str(R),'--vanilla','--slave','--file='+str(ROOT/'jdbc-probe-wire.R'),'--args',str(port),str(JAR),mode,out,str(ROOT/'fixtures/probe-v2/DbDiagnostics.R'),str(rows)],cwd=REPO,text=True,capture_output=True,timeout=16)
  journal=Path(out,'probe-events.tsv');j=journal.read_text() if journal.exists() else ''
  if p.returncode not in (0,2): print(p.stdout+p.stderr,flush=True)
 t.join(2);assert not errors,errors
 print(mode,case,rows,'exit',p.returncode,'last',p.stdout.splitlines()[-2:],flush=True)
 assert not any('SET ROWCOUNT' in e or e.startswith('packet:3') for e in events),events
 if case=='normal':assert p.returncode==0,p.stdout+p.stderr
 elif case=='late-error' and mode=='old':
  assert p.returncode==0, 'Legacy fixture no longer demonstrates the ignored trailing error'
 elif case=='late-error' and mode=='new':
  assert p.returncode==2 and 'Fixture late SQL failure' in p.stdout,p.stdout+p.stderr
  assert 'Statement.getMoreResults\tfirst-failure' in j,j
 elif case=='missing-terminal' and mode=='new':
  assert p.returncode==2,p.stdout+p.stderr
  assert 'Statement.executeQuery\tfirst-failure' in j,j
 return p
for n in (0,1,2):run('new','normal',n)
for case in ('late-error','missing-terminal'):
 for mode in ('old','new'):run(mode,case)
print('PASS: production R/rJava with '+JAR.name+': bounded rows, UTF-8/NULL, EOF, terminal errors, no hidden commands, small-only full buffering, incomplete responses fail before cleanup.')

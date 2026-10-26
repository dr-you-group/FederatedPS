# Local protocol regression using the production R probe and pinned JDBC JAR.
# No real database, credentials or HIWARE connection. Requires R/rJava and JDK.
import argparse,socket,struct,threading,subprocess,time
parser=argparse.ArgumentParser()
parser.add_argument('--r',required=True,help='R executable (not Rscript)')
parser.add_argument('--jar',required=True,help='Pinned mssql-jdbc-9.2.0.jre8.jar')
args=parser.parse_args()
from pathlib import Path
root=Path(__file__).resolve().parent
project=root.parent.parent

def exact(c,n):
 b=b''
 while len(b)<n:
  d=c.recv(n-len(b))
  if not d:raise EOFError()
  b+=d
 return b

def read(c):
 data=b''
 while True:
  h=exact(c,8);typ,status,n,spid,pid,win=struct.unpack('!BBHHBB',h)
  data+=exact(c,n-8)
  if status&1:return typ,data

def send(c,b):c.sendall(struct.pack('!BBHHBB',4,1,len(b)+8,0,1,0)+b)
def done(rows=0,cmd=0):return b'\xfd'+struct.pack('<HHQ',0x10 if rows else 0,cmd,rows)
def col(name):return struct.pack('<IHBB',0,0,0x38,len(name))+name.encode('utf-16le')
for mode in ['old','new']:
 sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen(1);port=sock.getsockname()[1];events=[];errors=[]
 def serve():
  try:
   c,a=sock.accept();c.settimeout(7)
   with c:
    typ,data=read(c);assert typ==18,(typ,data)
    send(c,b'\x00\x00\x0b\x00\x06\x01\x00\x11\x00\x01\xff'+b'\x0f\x00\x07\xd0\x00\x00\x02')
    typ,data=read(c);assert typ==16,typ
    ack=b'\x01'+bytes.fromhex('74000004')+bytes([7])+'Fixture'.encode('utf-16le')+bytes([15,0,7,208])
    send(c,b'\xad'+struct.pack('<H',len(ack))+ack+done())
    while True:
     typ,data=read(c)
     if typ!=1: events.append('packet:'+str(typ));continue
     # TDS 7.2 query messages begin with ALL_HEADERS; skip its length.
     header_len=struct.unpack('<I',data[:4])[0]
     sql=data[header_len:].decode('utf-16le');events.append(sql)
     if sql=='SET ROWCOUNT 2':
      # Simulate a proxy that never replies to this hidden connection command.
      time.sleep(3);break
     elif sql.startswith('SELECT CAST(1'):
      send(c,b'\x81\x02\x00'+col('ok')+col('session_id')+b'\xd1'+struct.pack('<ii',1,70)+done(1))
     elif sql=='SELECT 1 AS person_id INTO #fixture': send(c,done(3000000000,0xC2))
     else: send(c,done())
  except EOFError:pass
  except Exception as e:errors.append(repr(e))
  finally:sock.close()
 t=threading.Thread(target=serve,daemon=True);t.start()
 p=subprocess.run([args.r,'--vanilla','--slave','--file='+str(root/'test-jdbc-probe-wire.R'),'--args',str(project),str(Path(args.jar).resolve()),str(port),mode],text=True,capture_output=True,timeout=25)
 t.join(5)
 print(mode,'exit',p.returncode,'commands',events,'errors',errors,'output',p.stdout.strip(),flush=True)
 if p.returncode and mode=='new': print(p.stderr,flush=True)
 assert not errors
 if mode=='old':assert p.returncode!=0 and 'SET ROWCOUNT 2' in events and not any(s.startswith('SELECT CAST') for s in events)
 else:assert p.returncode==0 and 'SET ROWCOUNT 2' not in events and any(s.startswith('SELECT CAST') for s in events) and events.count('SELECT 1 AS person_id INTO #fixture')==1
print('PASS: production R probe + actual pinned JDBC 9.2.0: old probe blocks on hidden SET ROWCOUNT, new probe executes SELECT directly')

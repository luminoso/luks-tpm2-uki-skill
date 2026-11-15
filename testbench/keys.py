# keys.py SOCKET KEY... : send raw keys to a QEMU serial socket. Names: down up enter esc, text:STR
import socket, sys, time
names = {'down': b'\x1b[B', 'up': b'\x1b[A', 'enter': b'\r', 'esc': b'\x1b', 'space': b' '}
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
for k in sys.argv[2:]:
    data = k[5:].encode() if k.startswith('text:') else names[k]
    for b in data:
        s.send(bytes([b])); time.sleep(0.05)
    time.sleep(1.5)
s.close()

# type.py SOCKET TEXT : type TEXT + Enter on a QEMU serial socket, one byte at a time
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
for c in sys.argv[2].encode() + b"\r":
    s.send(bytes([c])); time.sleep(0.05)
time.sleep(0.5); s.close()

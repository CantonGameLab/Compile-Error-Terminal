import base64, os, sys, time
o = sys.stdout.buffer
payload = base64.b64encode(os.urandom(2 * 1024 * 1024))
o.write(b"\x1b]999;" + payload + b"\x07")
o.write(b"BIGOSC-DONE\r\n")
o.flush()
time.sleep(2.0)

import sys, time
o = sys.stdout.buffer
# ???? sixel:DCS 0;0;0 q "1;1;1;1 #0;2;0;0;0 #0~~
o.write(b'\x1bP0;0;0q"1;1;1;1#0;2;0;0;0#0~~\x1b\\')
o.write(b"SIXEL-DONE\r\n")
o.flush()
time.sleep(1.0)

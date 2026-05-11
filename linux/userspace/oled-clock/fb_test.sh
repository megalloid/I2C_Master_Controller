#!/bin/sh
# Test framebuffer bit-order/orientation on SSD1306 via /dev/fb0.
# Usage: fb_test.sh A|B|C|D
set -eu
killall -q oled-clock 2>/dev/null || true
sleep 0.3

case "${1:-A}" in
A)
  # only bit 0 of byte 0 (LSB-first => pixel (0,0); MSB-first => pixel (7,0))
  python3 -c "import sys; b=bytearray(1024); b[0]=0x01; sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "A: byte[0]=0x01"
  ;;
B)
  # only bit 7 of byte 0 (MSB)
  python3 -c "import sys; b=bytearray(1024); b[0]=0x80; sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "B: byte[0]=0x80"
  ;;
C)
  # whole first row lit (row-major)  =>  thin horizontal line on top (y=0)
  python3 -c "import sys; b=bytearray(1024); 
[setattr(b, '__setitem__', None) for _ in []]
for i in range(16): b[i]=0xFF
sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "C: row 0 all white"
  ;;
D)
  # whole first column lit (column 0 => bit 0 of every row's byte 0)
  python3 -c "import sys; b=bytearray(1024)
for y in range(64): b[y*16]=0x01
sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "D: col 0 LSB on each row"
  ;;
E)
  # whole first column lit assuming MSB-first => bit7 of every row's byte 0
  python3 -c "import sys; b=bytearray(1024)
for y in range(64): b[y*16]=0x80
sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "E: col 0 MSB on each row"
  ;;
F)
  # fill: every other row white  => stripes
  python3 -c "import sys; b=bytearray(1024)
for y in range(64):
  v = 0xFF if (y%2)==0 else 0x00
  for x in range(16): b[y*16+x]=v
sys.stdout.buffer.write(bytes(b))" > /dev/fb0
  echo "F: horizontal stripes 1px"
  ;;
G)
  # solid white
  python3 -c "import sys; sys.stdout.buffer.write(b'\\xFF'*1024)" > /dev/fb0
  echo "G: all white"
  ;;
Z)
  python3 -c "import sys; sys.stdout.buffer.write(b'\\x00'*1024)" > /dev/fb0
  echo "Z: all black"
  ;;
*)
  echo "unknown pattern $1"; exit 1
  ;;
esac

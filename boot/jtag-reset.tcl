# Просто сделать system reset через JTAG.
connect

puts "\n=== JTAG chain ==="
jtag targets

puts "\n=== debug targets ==="
targets

# Стопаем оба ядра
catch { targets -set -filter {name =~ "*Cortex-A9*MPCore #0*"} ; stop }
catch { targets -set -filter {name =~ "*Cortex-A9*MPCore #1*"} ; stop }

# System reset (ставит CPU в safe state, без перепрошивки bitstream)
catch { targets -set -filter {name =~ "*Cortex-A9*MPCore #0*"} ; rst -system } err
puts "rst -system: $err"
after 300

puts "\n=== после reset ==="
targets

disconnect
exit 0

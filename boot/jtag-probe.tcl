# Diagnostic-скрипт: проверяет, видит ли xsct JTAG-цепочку и кто там есть.
puts "\n--- connect ---"
connect

puts "\n--- targets list (raw) ---"
set lst [targets]
puts $lst

puts "\n--- jtag targets ---"
catch { jtag targets } jtag_lst
puts $jtag_lst

puts "\n--- хост hw_server: ---"
catch { socket -server [list] 3121 } sk
puts $sk

disconnect
exit 0

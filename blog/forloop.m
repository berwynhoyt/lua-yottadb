; Run with: time yottadb -run forloop

loop()
 new i,n
 set n=0
 for i=1:1:100000000 do
 .set n=n+1
 write "counted to ",n,!
 quit

; Run with: time yottadb -run zadloop

traverse()
 new x,y,z,node,cnt
 set node="",cnt=0
 for  s node=$O(^BCAT("lvd",node)) q:node=""  s cnt=cnt+1
 write cnt," records",!
 quit

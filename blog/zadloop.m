; Run with: time yottadb -run %T1^zadloop

%T1 ;sub
 n x,y,z,node,cnt
 s node="",cnt=0
 f  s node=$O(^BCAT("lvd",node)) q:node=""  s cnt=cnt+1
 w !,cnt_" records"
 q

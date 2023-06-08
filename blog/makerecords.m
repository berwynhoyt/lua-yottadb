make5()
 do makeRecords($name(^BCAT("lvd")),5)
 quit

make10k()
 do makeRecords($name(^BCAT("lvd")),10000)
 quit

make1M()
 do makeRecords($name(^BCAT("lvd")),1000000)
 quit

make4M()
 do makeRecords($name(^BCAT("lvd")),4000000)
 quit

makeRecords(subs,records)
 ; Given subscripts list `subs`, create a counted table of `records` entries at that subscript
 new cnt,name,code,i
 for i=1:1:records do
 .set @subs@(i)=$random(2147483646)
 quit
function f()
    local n=0
    for i=1, 100000000 do  n=n+1  end
    print("Counted to "..n)
end

f()

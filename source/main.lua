--back end
local RFLevel = 1
local ifthen = [[<WELL>]]
local loop   = [[<REVIVE>]]
local writes = [[<WRITE>]]
local prints = [[<PRINT>]]
local dates  = [[<TIME>]]
local locals = [[<LOCAL>]]
local string = [[<STRING>]]
local rand   = [[<GUESS>]]
local commas = [[,]]
local sleep  = [[<SLEEP>]]
local elses  = [[<ELSE>]]
local varis  = [[___]]
local opens  = [[<CREATE>]]
local state  = [[<STATE>]]
local reads  = [[<READ>]]
local closes = [[<CLOSE>]]
local basket = [[<BASKET>]]
local done = [[<DONE>]]
local __for = [[<FOR>]]
local lua = [[<LUA>]]
--front end
local background = [[FILL:]]
local size = [[XY:]]
local color = [[RGB:]]
local align = [[POSITION:]]
local display = [[DISPLAY:]]
local displayx = [[DISPLAYX:]]
local linkframe = [[LINKFRAME:]]
local linkframex = [[LINKFRAMEX:]]
local attachment = [[ATTACH:]]
local attachmentx = [[ATTACHX:]]
local attachmentl = [[ATTACHL:]]
local bracket = [[BRACKET:]]
local html = [[HTML:]]

local UIDirectory = [[source/testing.html]]
local amounts = 0
local M_file = ""
local unnecessary_output = false
if unnecessary_output == true then 
io.write("@",os.date(),"//",os.time(),": in process")
end
local tasks = 0
local rands = false
local endmount = 0

io.open(UIDirectory:gsub("\n",""),"w"):write(""):close()

io.output("source/execute.lua")
for line in io.lines("CELL2") do -- change name if needed

  local Translation = line:upper()
  local line = line 


  if Translation:find(loop) and Translation:find(sleep)  and not Translation:find(lua) then
    io.write("while")
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),"")
     FP1:match("^%s*(.-)%s*$")
     local FP2 = FP1
     io.write(" os.execute('sleep",FP2,"')")
     io.write(" do\n")
    endmount = endmount + 1
  else
if Translation:find(loop) and not Translation:find(lua) then
  io.write("while true do\n")
  endmount = endmount + 1
end
end
end
amounts = amounts + 1
for line in io.lines("CELL2") do -- change name if needed
  amounts = amounts + 1
  local Translation = line:upper()
  local line = line

  if Translation:find(opens) and not Translation:find(state) and not Translation:find(reads) and not Translation:find(lua) then
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(opens,""):gsub(opens:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       M_file = FP2
       io.write("local ",varis,RFLevel," = ","io.open('",FP2,"','w')\n")
  end

  if Translation:find(locals) and Translation:find(reads) and not Translation:find("____") and not Translation:find("FUNCTION") and not Translation:find(lua) then


     local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,""):gsub(ifthen,""):gsub(line,"")
    io.write("local ",varis,RFLevel," = ")
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
    io.write("io.open('",M_file,"','r'):read('*a')\n")
  end

if Translation:find(locals) and Translation:find("FUNCTION") and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),"")
     FP1:match("^%s*(.-)%s*$")
     io.write("local function ",varis,RFLevel,"(")
    RFLevel = RFLevel + 1
    io.write(varis,RFLevel,")\n")
  end


  if Translation:find(basket) and not Translation:find(lua) then

     local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,""):gsub(ifthen,""):gsub(basket,""):gsub(basket:lower(),"")
    io.write("local ",varis,RFLevel," = {",FP1,"}\n")
  end


    if Translation:find(sleep) and not Translation:find(loop) and Translation:find(sleep)and not Translation:find(lua) then
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(sleep,""):gsub(sleep:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nos.execute('sleep",FP2,"')\n")
    end

    if Translation:find(ifthen) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(line,"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nif ",FP2," then\n")
    endmount = endmount + 1
    end
if Translation:find(lua) then
   local FP1 = line:gsub(lua,""):gsub(lua:lower(),"")
     FP1:match("^%s*(.-)%s*$")
     local FP2 = FP1
     io.write(FP2,"\n")
  end
    if Translation:find(__for) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub("<",""):gsub(">","")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write(FP2," do\n")
    endmount = endmount + 1
    end
    if Translation:find(done) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(line,"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nend\n")
    endmount = endmount - 1
    end






  if not Translation:find(ifthen) and not Translation:find(lua) then



    if Translation:find(varis) and Translation:find(state) and not Translation:find("FOR") and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(closes,""):gsub(closes:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
      FP1:match("^%s*(.-)%s*$")
      local removed = FP1:gsub(line,"")
      io.write(varis,RFLevel,":write(",removed,")\n")
      if Translation:find(closes) and not Translation:find(lua) then
      io.write(varis,RFLevel,":close()\n")
      else
      io.write("")
    end
    end

    if Translation:find(varis) and not Translation:find(state) and not Translation:find("____") and not Translation:find(reads) and not Translation:find(prints) and not Translation:find(writes)  and not Translation:find("FOR") and not Translation:find(locals) and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
         FP1:match("^%s*(.-)%s*$")
      if Translation:find("1") or Translation:find("2") or Translation:find("3") or Translation:find("4") or Translation:find("5") or Translation:find("6") or Translation:find("7") or Translation:find("8") or Translation:find("9") or Translation:find("0") then
         io.write(line,"")
      else
        io.write(Translation)
    end
end
    if Translation:find(varis) and Translation:find(reads) and not Translation:find(locals) and not Translation:find("____") and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
      FP1:match("^%s*(.-)%s*$")
      io.write("io.open('",M_file,"','r'):read()\n")
    end

  if Translation:find(state) and not Translation:find(varis) and not Translation:find(lua) then
           local FP1 = line:gsub(closes,""):gsub(closes:lower(),""):gsub(state,""):gsub(state:lower(),"")
        FP1:match("^%s*(.-)%s*$")
        local FP2 = FP1
        local removed = FP2:gsub(line,"")
        io.write(varis,RFLevel,":write(",removed,")\n")
      if Translation:find(closes) then
      io.write(varis,RFLevel,":close()\n")
      else
      io.write("")
      end
  end


  end -- 121












if Translation:find(locals) and not Translation:find(reads) and not Translation:find("FUNCTION") then
    if Translation:find(dates) and Translation:find(locals) and not Translation:find(reads) and not Translation:find(state) and not Translation:find(lua) then
    local FP2 = line:gsub(loop,""):gsub(writes,""):gsub(prints,""):gsub(string,""):gsub(locals,"")
    FP2 = FP2:match("^%s*(.-)%s*$")
    io.write("local ",varis,RFLevel," = os.date()\n")
    end
    if Translation:find(rand) and Translation:find(commas) and not Translation:find(dates) and not Translation:find(reads) and not Translation:find(state) and not Translation:find(lua) then
   local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
      io.write("local ",varis,RFLevel," =".." math.random(",FP1,")\n")
  else
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
    FP1:match("^%s*(.-)%s*$")

      if Translation:find("[%d]") and not Translation:find(lua) and not Translation:find(dates) then
        io.write("local ",varis,RFLevel," = ",FP1,"\n")
      else
      if Translation:find("[A-Z]") and not Translation:find(lua) and not Translation:find(dates) then
        io.write("local ",varis,RFLevel," = [[",FP1,"]]\n")
      end
      end
    end
    if Translation:find(string) and not Translation:find(lua) then
  io.write("\n")
   local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,"")
    FP1:match("^%s*(.-)%s*$")
    if Translation:find("1") or Translation:find("2") or Translation:find("3") or Translation:find("4") or Translation:find("5") or Translation:find("6") or Translation:find("7") or Translation:find("8") or Translation:find("9") or Translation:find("0") and not Translation:find(dates) then
    io.write(varis,RFLevel," ="..FP1.."\n")
    else
    io.write(varis,RFLevel," =[["..FP1.."]]\n")
    end
end
end

if rands == false then


--1234
if not Translation:find(reads) and not Translation:find(state) then
if Translation:find(string) and Translation:find(prints) or Translation:find(locals) and Translation:find(prints) and not Translation:find(state) and not Translation:find(reads) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("print(",varis,RFLevel,")\n")
  else
if Translation:find(string) and Translation:find(writes) or Translation:find(locals) and Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("io.write(",varis,RFLevel,")\n")

else

if Translation:find("+") or Translation:find("-") or Translation:find("*") or Translation:find("/") or Translation:find(varis) and not Translation:find("____") and not Translation:find(state) and not Translation:find(lua) then

  if unnecessary_output == true then
  io.write("\n > Asking for math")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  if Translation:find(string) and Translation:find(prints) or Translation:find(locals) and Translation:find(prints) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("print(",varis,RFLevel,")\n")
  else
  if Translation:find(string) and Translation:find(writes) or Translation:find(string) and Translation:find(writes) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("io.write(",varis,RFLevel,")\n")
  else
  if Translation:find(prints) and not Translation:find(lua) then
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print(",FP1,")\n")
  else
  if Translation:find(writes) and not Translation:find(lua) then
 local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP1 = FP1:match("^%s*(.-)%s*$"):gsub(writes,""):gsub(writes:lower(),"")
  io.write("io.write(",FP1,")\n")
  end
  end
  end
  end --1234


else
if Translation:find(prints) and not Translation:find(state) and not Translation:find(lua) then

  local Anti_mixup = false

  if Translation:find(dates) and not Translation:find(lua) then
  Anti_mixup = true
  if unnecessary_output == true then
  io.write("> Asking for date \n")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  local FP1 = "os.date()"
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print(",FP1,")\n")


else
if Anti_mixup == false then
  if unnecessary_output == true then
  tasks = tasks + 1
  io.write("(",tasks,")\n")
  end
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print('",FP1,"')\n")
end
end
else

if Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then

  local Anti_mixup = false

  if Translation:find(dates) and not Translation:find(lua) then
  Anti_mixup = true
  if unnecessary_output == true then
  io.write("> Asking for date \n")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  local FP1 = "os.date()"
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("io.write(",FP1,")\n")

else
if Anti_mixup == false then
  if unnecessary_output == true then
  tasks = tasks + 1
  io.write("(",tasks,")\n")
  end
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("io.write('",FP1,"')\n")

else

if Translation:find("+") or Translation:find("-") or Translation:find("*") or Translation:find("/") and not Translation:find(state) and not Translation:find(lua) then

    if unnecessary_output == true then
    io.write(" > Asking for math\n")
    end

    tasks = tasks + 1
    if unnecessary_output == true then
    io.write("(",tasks,")\n")
    end

    if Translation:find(prints) and not Translation:find(state) and not Translation:find(lua) then

    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    io.write("print(",FP1,")\n")

    else

    if Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    io.write("io.write(",FP1,")\n")
    end
    end
end
end
end
end
end
end

end
end


end
if unnecessary_output == true then
  io.write("",RFLevel,"\n")
end
  RFLevel = RFLevel + 1
end
end

for i = 1, endmount do
  io.write("end\n")
end

local htmlStart = io.open(UIDirectory,"w")
htmlStart:write("<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Generated</title></head><body>"):close()









for line in io.lines("CELL2") do -- change name if needed
  amounts = amounts + 1
  local Translation = line:upper()
  local line = line



if Translation:find(background) then
    local _ = io.open(UIDirectory,"a")
    local FP1 = line:gsub(background,""):gsub(background:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    _:write("<body style='background-color:",FP1,";'>")
end

    if Translation:find(displayx) then
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(displayx,""):gsub(displayx:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
        _:write("<h2 style='font-size:15px; font-style:serif;'>",FP1,"</h2>")
  end

  if Translation:find("AUPD:") then
    local _ = io.popen('dir /b *.html')

    _:write([[<body style="overflow:hidden;"><div id="content"><script>function updateContent(){fetch('source/index.html').then(response => response.text()).then(data =>{document.getElementById('content').innerHTML = data;});}setInterval(updateContent,1000);</script>]])
end
  if Translation:find(bracket) then
  local _ = io.open(UIDirectory,"a")
  _:write("<a style ='")
  end


  local sync= false
  local model = [[WORLD:]]
  local char = [[CHARACTER:]]
  if Translation:find(model) then -- old feature, probably will be removed down the line..
    sync= true
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(model,""):gsub(model:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
    _:write([[
      <body oncontextmenu="return false;" onmousedown="if(event.button===2)this.requestPointerLock()">
      <script src="https://unpkg.com/fflate"></script>
      <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/loaders/FBXLoader.js" ></script>
      <script>
        const workspace = new THREE.Scene(), perspective = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000)
        const engine = new THREE.WebGLRenderer({alpha:true});
        engine.setSize(window.innerWidth,window.innerHeight);

        document.body.appendChild(engine.domElement);
        perspective.position.z = 5;
        perspective.position.y = 5;
        perspective.position.x = 5;

        const brightness = new THREE.AmbientLight(0xcdd1b4, 1)
        workspace.add(brightness);

        workspace.background = null;

        const FL = new THREE.DirectionalLight(0xcdd1b4,1.5);
        FL.position.set(3.5,4,2.5);
        workspace.add(FL);




        new THREE.FBXLoader().load(']],FP1)

    _:write([[', (fbx) => {workspace.add(fbx); animate(); });



        function animate()
          {
          requestAnimationFrame(animate);
          engine.render(workspace, perspective);

          }
          window.addEventListener('resize',()=> {engine.setSize(window.innerWidth,window.innerHeight); perspective.aspect = window.innerWidth / window.innerHeight; perspective.updateProjectionMatrix();});




const loadtexture = new THREE.TextureLoader();
const texture = loadtexture.load("WorldSpace/Texture/maptexture.png");
        const loader = new THREE.FBXLoader();
        loader.load(']],FP1)


        _:write([[', (fbx) => {
          fbx.traverse((child) => { 
            if (child.isMesh) {
              child.material.map = texture;
          child.material.needsUpdate = true;
            }
          });
          workspace.add(fbx);
          animate();
        }
          )

      document.addEventListener("mousemove", e => {
      perspective.rotation.y -= e.movementX * 0.001;
      })
      document.addEventListener("keydown", e => {
      const scene = new THREE.Scene();
      const raycaster = new THREE.Raycaster();
      const move = new THREE.Vector3();
      const speed = 0.255;
      const direction = new THREE.Vector3();
          if (e.key === "w"){ perspective.getWorldDirection(direction);
          perspective.position.addScaledVector(direction, speed);

          }
          if (e.key === "s"){ perspective.getWorldDirection(direction);
          perspective.position.addScaledVector(direction, -speed);

          }
          if (e.key === "a"){ 
          perspective.getWorldDirection(direction);
          direction.crossVectors(perspective.up,direction).normalize();
          perspective.position.addScaledVector(direction, speed);

          }
          if (e.key === "d"){ perspective.getWorldDirection(direction).normalize();
          direction.crossVectors(perspective.up,direction).normalize();
          perspective.position.addScaledVector(direction, -speed);

          }


    raycaster.set(perspective.position, move.clone().normalize());
      const intersects = raycaster.intersectObjects(scene.children, true);
      const closest = intersects.length ? intersects[0].distance : Infinity;
      if (closest > move.length()) {
      perspective.position.add(move);
      }
      });
      </script>
      </body>
      ]]) 

  end




  if Translation:find(size) then
    local _ = io.open(UIDirectory,"a")
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),""):gsub(size,""):gsub(size:lower(),"")
    _:write("<a style='")
  if Translation:find(size) and not Translation:find([["]]) then
      _:write("transform: scale(",FP1,"); display: inline-block;")
  end
  _:write("'>")
  end

  if Translation:find(attachmentl) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachmentl,""):gsub(attachmentl:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
       _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:240px; height:420px;'>")
  end


  if Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
      _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:70px; height:70px; border-radius:2.5px;'>")
  end
  if Translation:find(attachmentx) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachmentx,""):gsub(attachmentx:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
       _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:240px; height:240px;'>")
  end






    if Translation:find(display) then
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(display,""):gsub(display:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
        _:write("<h2 style='font-size:12px; font-style:serif;'>",FP1,"</h2>")
  end
  if Translation:find(linkframe) and not Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom","")
    _:write("<iframe ")
    _:write("src='",FP1,"' ")
    if Translation:find(align) then
      FP1 = FP1:match("^%s*(.-)%s*$")
      if line:find("middle") then
        _:write("align='middle' ")
      else
      if line:find("left") then
        _:write("align='left' ")
      else
      if line:find("right") then
        _:write("align='right' ")
      else
      if line:find("top") then
        _:write("align='top' ")
      else
      if line:find("bottom") then
        _:write("align='bottom' ")
      else
      end
      end
      end
      end
      end
      end
    _:write("style ='display:block; margin:0 auto; width:15%; height:15%;' frameborder='0'></iframe>")
  end

  if Translation:find(linkframex) and not Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(linkframex:lower(),""):gsub(linkframex,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom","")
    _:write("<iframe")
    _:write(" src='",FP1,"' ")
    if Translation:find(align) then
      FP1 = FP1:match("^%s*(.-)%s*$")
      if line:find("middle") then
        _:write("class='middle' ")
      else
      if line:find("left") then
        _:write("class='left' ")
      else
      if line:find("right") then
        _:write("class='right' ")
      else
      if line:find("top") then
        _:write("class='top' ")
      else
      if line:find("bottom") then
        _:write("class='bottom' ")
      else
      end
      end
      end
      end
      end
      end
    _:write([[style ="border-radius:20px display:block; margin:0; width:100%; height:125%;" frameborder="0" scrolling="no""></iframe>]])
  end



  ---------------------------------
if Translation:find(align) or Translation:find(color) and not Translation:find(linkframe) and not Translation:find(linkframe) and not Translation:find(attachment) and not Translation:find(background) then
    anti_loop = true

      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(color,""):gsub(color:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub("center",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),"")
      FP1 = FP1:match("^%s*(.-)%s*$")
    local _ = io.open(UIDirectory,"a")
    if Translation:find(color) and not Translation:find(linkframe) then
     _:write("color:",FP1,";")
    else

      if Translation:find(align) and line:find("center") and not Translation:find(linkframe) and not Translation:find(color) then

       _:write("text-align:center;")
        _:write("'>")
      else
        if Translation:find(align) and line:find("left") and not Translation:find(linkframe) and not Translation:find(color) then

         _:write("text-align:left;")
          _:write("'>")
        else
        if Translation:find(align) and line:find("right") and not Translation:find(linkframe) and not Translation:find(color) then

         _:write("text-align:right;")
            _:write("'>")
end
        end
      end
  if Translation:find(color) and not Translation:find(linkframe) and not Translation:find(align) then

      _:write("'>")
    end
end

    
---------------------------------------------------
    if Translation:find(html) then
     local FP1 = line:gsub(html,""):gsub(html:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       _:write(FP2,"\n")
    end













end
end ---
io.close()
local htmlFile = io.open(UIDirectory,"a")
if htmlFile then
  htmlFile:write("</body></html>")
  htmlFile:close()
end
os.execute("sleep 2")
os.execute("luajit source/execute.lua")
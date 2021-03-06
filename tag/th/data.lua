utf8 = require 'lua-utf8'

function cleanup(word)
   if word:match('^http') then
      return 'URL'
   elseif word:match('^@') then
      return '@@@@'
   elseif word:match('^#') then
      return '####'

   elseif word == '"' then
      return ','
   elseif word == ':)' or word == ':(((' or word == ':D' or word == '=)' or word == ':-)' or word == '=(' or word == '(=' or word == '=[[' then
      return ';)'
   elseif word == '<3' then
      return '&lt;3'
   end
   return word
end

function conllBuildVocab(files)

   local vocab_word = {}
   local vocab_ch = {}
   
   local maxw = 0
   local maxs = 0
   for i=1,#files do
      if files[i] ~= nil and files[i] ~= 'NONE' then
	 local tsfile = io.open(files[i], 'r')
	 local sl = 0
	 for line in tsfile:lines() do
	    local states = line:split('%s+')
	    if #states ~= 0 then
	       sl = sl + 1
	       local w = states[1]
	       local cleaned = cleanup(w)
	       vocab_word[cleaned] = vocab_word[cleaned] or 1

	       maxw = math.max(maxw, #w)
--[[
	       for k=1,#w do
		  local ch = w:sub(k, k)
		  vocab_ch[ch] = vocab_ch[ch] or 1
	       end
--]]

	       local l = utf8.len(w)
	       for _, ch in utf8.next, w do
		  if ch ~= nil then
		     ch = utf8.char(ch)
		     vocab_ch[ch] = vocab_ch[ch] or 1
		  end
	       end
	    else
	       maxs = math.max(maxs, sl)
	       sl = 0

	    end
	 end
      end
   end
   return maxs, maxw, vocab_ch, vocab_word
end

function conllLines(tsfile)

    local lbl = {}
    local lbls = {}
    local txt = {}
    local txts = {}
   
    for line in tsfile:lines() do
       local state = line:split('%s+')

       -- end of sentence
       if #state == 0 then
	  -- time to return the set
	  
	  table.insert(txts, txt)
	  table.insert(lbls, lbl)
	  txt = {}
	  lbl = {}
       else
	  local label = state[#state]
	  local word = state[1]
	  table.insert(txt, word)
	  table.insert(lbl, label)
       end
    end
    return txts, lbls
end

function conllSentsToIndices(file, words, chars, maxs, maxw, f2i, options)
   
    local ts = options.ooc and FileBackedStore() or TableBackedStore()
    local tsfile = io.open(file, 'r')
    local linenum = 1
    
    local chsz = chars.dsz
    local mxlen = maxs
    local mxcfiltsz = torch.max(torch.LongTensor(options.cfiltsz))
    local halfcfiltsz = math.floor(mxcfiltsz / 2)

    print('Word vector sz ' .. chsz)
    
    local non = 0
    local tot = 0

    local txts = {}
    local lbls = {}

    txts, lbls = conllLines(tsfile)

    local idx = 0

    -- for each training example
    for i,v in pairs(txts) do

       local xs_ch = torch.LongTensor(mxlen, maxw):fill(1)
       local xs = torch.LongTensor(mxlen):fill(1)
       local ys = torch.LongTensor(mxlen):fill(0)

       local lv = lbls[i]
       local length = mxlen
       for j=1,mxlen do -- tok in pairs(v) do
	  
	  if j > #v then
	     length = j
	     break
	  end

	  local w = v[j]
	  local nch = math.min(#w, maxw - 2*halfcfiltsz)
	  local label = lv[j]
	  if not f2i[label] then
	     idx = idx + 1
	     f2i[label] = idx
	  end
	  
	  ys[j] = f2i[label]
	  if words.vocab then
	     xs[j] = words.vocab[cleanup(w)]
	  end
--[[

         for k=1,nch do
            local ch = w:sub(k, k)
            xs_ch[{j, k+halfcfiltsz}] = chars.vocab[ch]
         end
--]]
	  for k, ch in utf8.next, w do
	     if k < nch then
		ch = utf8.char(ch)
		xs_ch[{j, k+halfcfiltsz}] = chars.vocab[ch]
	     end
	  end

       end

       ts:put({x=xs,xch=xs_ch,y=ys,id=i, length=length})

    end

    return ts, f2i, txts
end


-- Create a valid split of this data store, splitting on a fraction
function validSplit(dataStore, splitfrac, ooc)
   local train = ooc and FileBackedStore() or TableBackedStore()
   local valid = ooc and FileBackedStore() or TableBackedStore()
   local numinst = dataStore:size()
   local heldout = numinst * splitfrac
   local holdidx = numinst - heldout
   
   for i=1,numinst do
      local txy = dataStore:get(i)
      if i < holdidx then
	 train:put(txy)
      else
	 valid:put(txy)
      end
      
   end
   
   return train, valid
end

function batch(ts, start, batchsz)
   local ex = ts:get(start)
   local siglen = ex.x:size(1)
   local maxw = ex.xch:size(2)
   local xs_ch = torch.LongTensor(batchsz, siglen, maxw):fill(1)
   local xs = torch.LongTensor(batchsz, siglen):fill(1)
   local ys = torch.LongTensor(batchsz, siglen):fill(0)
   local ids = torch.LongTensor(batchsz):fill(0)
   local lengths = torch.LongTensor(batchsz):fill(0)
   
   local sz = ts:size()
   local idx = (start-1)*batchsz + 1
   for i=1,batchsz do

      -- wrap
      if idx > sz then
	 idx = 1
      end

      ex = ts:get(idx)
      xs_ch[i] = ex.xch
      xs[i] = ex.x
      ys[i] = ex.y
      ids[i] = ex.id
      lengths[i] = ex.length
      idx = idx + 1
   end
   return {x=xs, xch=xs_ch,y=ys,id=ids,length=lengths} 

end


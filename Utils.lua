--Retrieves audio datasets. Currently retrieves the AN4 dataset by giving the folder directory.
require 'lfs'
require 'audio'
require 'xlua'
require 'lmdb'
require 'torch'
require 'Mapper'

-- manipulate with this object
local util = {}

local function split(s, p)
    local rt = {}
    string.gsub(s, '[^' .. p .. ']+', function(w) table.insert(rt, w) end)
    return rt
end

local function trans2tokens(line, mapper)
    --[[
        input:
            line: ERASE C Q Q F SEVEN (id)
        output:
            label: {3,7,1,2,8}
            line: erase c q q f seven
    --]]
    line = string.lower(line)
    line = line:gsub('^%s', ''):gsub('', ''):gsub('', ''):gsub('%(.+%)', ''):gsub('%s$', ''):gsub('<s>', ''):gsub('</s>', '')
    line = line:match("^%s*(.-)%s*$")
    local label = mapper:encodeString(line)
    return torch.serialize(label), torch.serialize(line)
end

local function start_txn(path, name)
    local db = lmdb.env {
        Path = path,
        Name = name
    }
    db:open()
    local txn = db:txn()
    return db, txn
end

local function end_txn(db, txn)
    txn:commit()
    db:close()
end

function util.mk_lmdb(root_path, index_path, dict_path, out_dir, windowSize, stride)

    local startTime = os.time()
    local mapper = Mapper(dict_path)

    -- start writing
    local db_spect, txn_spect = start_txn(out_dir .. '/spect', 'spect')
    local db_label, txn_label = start_txn(out_dir .. '/label', 'label')
    local db_trans, txn_trans = start_txn(out_dir .. '/trans', 'trans')

    local cnt = 1
    local show_gap = 100
    for line in io.lines(index_path) do
        local wave_path, trans = split(line, '@')[1], split(line, '@')[2]

        -- make label
        local label, modified_trans = trans2tokens(trans, mapper)

        -- make spect
        local wave = audio.load(root_path .. wave_path)
        local spect = audio.spectrogram(wave, windowSize, 'hamming', stride) -- freq-by-frames tensor

        -- put into lmdb
        spect = spect:float()

        -- normalize the data
        local mean = spect:mean()
        local std = spect:std()
        spect:add(-mean)
        spect:div(std)

        txn_spect:put(cnt, spect)
        txn_label:put(cnt, label)
        txn_trans:put(cnt, modified_trans)

        -- commit buffer
        if cnt % show_gap == 0 then
            txn_spect:commit(); txn_spect = db_spect:txn()
            txn_label:commit(); txn_label = db_label:txn()
            txn_trans:commit(); txn_trans = db_trans:txn()
        end

        xlua.progress(cnt % show_gap + 1, show_gap)
        cnt = cnt + 1
    end
    print('total ' .. cnt .. ' items in ' .. os.time() - startTime .. 's')
    -- close
    end_txn(db_spect, txn_spect)
    end_txn(db_label, txn_label)
    end_txn(db_trans, txn_trans)
end

return util

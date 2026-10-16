--------------------------------------------------------------------------------
-- statistics.lua
-- Learning metrics using timestamped reviews and legacy review count totals.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- Metrics Collection & Aggregation
--------------------------------------------------------------------------------

function M.get(store, stamp)
    stamp = stamp or os.time()
    local day = math.floor(stamp / 86400)
    local activity, difficult = {}, {}

    local function collect(db, table_name)
        local rows, err = db:query([[SELECT date(rated_at,'unixepoch') AS day, count(*) AS total,
            sum(CASE WHEN grade>0 THEN 1 ELSE 0 END) AS recalled FROM ]] .. table_name
            .. ' WHERE rated_at<=? GROUP BY day', { stamp })
        assert(rows, err)
        for _, row in ipairs(rows) do
            if row.day then
                local bucket = activity[row.day] or { total = 0, recalled = 0 }
                bucket.total = bucket.total + row.total
                bucket.recalled = bucket.recalled + row.recalled
                activity[row.day] = bucket
            end
        end
        rows, err = db:query([[SELECT lower(w.word) AS word,count(*) AS total,
            sum(CASE WHEN r.grade=0 THEN 1 ELSE 0 END) AS again
            FROM ]] .. table_name .. [[ r JOIN words w ON w.id=r.word_id
            WHERE r.rated_at>=? AND r.rated_at<=? GROUP BY lower(w.word)]],
            { (day - 29) * 86400, stamp })
        assert(rows, err)
        for _, row in ipairs(rows) do
            local item = difficult[row.word] or { word = row.word, total = 0, again = 0 }
            item.total = item.total + row.total
            item.again = item.again + row.again
            difficult[row.word] = item
        end
    end

    collect(store.web, 'review_log')
    if store.shared then
        collect(store.shared, 'reviews')
    end

    local days, total, recalled = {}, 0, 0
    for offset = 29, 0, -1 do
        local date = os.date('!%Y-%m-%d', (day - offset) * 86400)
        local bucket = activity[date] or { total = 0, recalled = 0 }
        days[#days + 1] = {
            date = date,
            total = bucket.total,
            recalled = bucket.recalled,
        }
        total = total + bucket.total
        recalled = recalled + bucket.recalled
    end

    local streak, cursor = 0, day
    if not activity[os.date('!%Y-%m-%d', day * 86400)] then
        cursor = cursor - 1
    end
    while activity[os.date('!%Y-%m-%d', cursor * 86400)] do
        streak = streak + 1
        cursor = cursor - 1
    end

    local words, unique, due = store:words(), {}, 0
    local mastery = { new = 0, learning = 0, reviewing = 0, mastered = 0 }
    local forecast_counts = { 0, 0, 0, 0, 0, 0, 0 }
    local today_end = (day + 1) * 86400 - 1

    for _, row in ipairs(words) do
        local key = row.word:lower()
        if row.due_at <= stamp then
            due = due + 1
        end
        if row.due_at <= today_end then
            forecast_counts[1] = forecast_counts[1] + 1
        else
            local due_day = math.floor(row.due_at / 86400)
            local diff = due_day - day
            if diff >= 1 and diff <= 6 then
                forecast_counts[diff + 1] = forecast_counts[diff + 1] + 1
            end
        end
        if not unique[key] then
            unique[key] = row
        end
    end

    local word_count = 0
    for _, row in pairs(unique) do
        word_count = word_count + 1
        local reviews = row.review_count or 0
        local is_tui = row.collection == 'tui'
        local span = is_tui and (row.interval_days or 0) or (row.streak or 0)
        if reviews == 0 then
            mastery.new = mastery.new + 1
        elseif (is_tui and span >= 14) or (not is_tui and (span >= 4 or reviews >= 5)) then
            mastery.mastered = mastery.mastered + 1
        elseif (is_tui and span >= 3) or (not is_tui and (span >= 2 or reviews >= 2)) then
            mastery.reviewing = mastery.reviewing + 1
        else
            mastery.learning = mastery.learning + 1
        end
    end

    local forecast = {}
    for offset = 0, 6 do
        forecast[#forecast + 1] = {
            date = os.date('!%Y-%m-%d', (day + offset) * 86400),
            due = forecast_counts[offset + 1],
        }
    end

    local lifetime = store.web:query('SELECT COALESCE(sum(review_count),0) AS total FROM words')[1].total
    if store.shared then
        local rows, err = store.shared:query('SELECT count(*) AS total FROM reviews')
        assert(rows, err)
        lifetime = lifetime + rows[1].total
    end

    local hardest = {}
    for _, row in pairs(difficult) do
        if row.again > 0 then
            hardest[#hardest + 1] = row
        end
    end
    table.sort(hardest, function(a, b)
        if a.again ~= b.again then
            return a.again > b.again
        end
        return a.word < b.word
    end)
    while #hardest > 10 do
        table.remove(hardest)
    end

    return {
        date = os.date('!%Y-%m-%d', stamp),
        saved_words = word_count,
        due_cards = due,
        today_reviews = days[#days].total,
        streak = streak,
        lifetime_reviews = lifetime,
        period_reviews = total,
        recalled = recalled,
        recall_rate = total > 0 and recalled / total * 100 or nil,
        mastery = mastery,
        forecast = forecast,
        days = days,
        difficult = hardest,
    }
end

return M

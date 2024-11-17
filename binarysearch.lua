function binary_search(array, value)
    local low = 1
    local high = #array

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local mid_value = array[mid]

        if mid_value < value then
            low = mid + 1
        elseif mid_value > value then
            high = mid - 1
        else
            return mid
        end
    end

    return nil
end

res = binary_search({2,4,6,8,9}, 6)
assert(res == 3, "Expected 3, got " .. res)

res = binary_search({2,4,6,8,9}, 7)
assert(res == nil, "Expected nil")

res = binary_search({}, 1)
assert(res == nil, "Expected nil")

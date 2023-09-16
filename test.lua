describe("my_test", function()
    it("true", function()
        assert.True(1==1)
    end)

    it("yeah", function()
        assert.truthy("Yup")
    end)

    it("lots", function()
        assert.are.same({table="great"}, {table="great"})
        assert.True(1==2)
    end)

    it("start", function()
        print("Hello World")
        print("10!=", fact(10))
        print(math.pi/4)
        a = 15
        print(a^2)
        n = norm(3.4, 1.0)
        print(n)
        print(twice(n))
    end)

    it("type", function()
        print(type(true))
        print(type(io.stdin))
        print(type({}))
    end)

    it("args", function()
        for k, v in pairs(arg) do
            print(k, v)
        end
    end)

    it("savefile", function()
        SaveCharacterData("ross", "7", "xteam")
    end)

    it("read", function()
        file = io.open("data.txt")
        lines = file:lines()
        print("contents of file:")
        for line in lines do
            print("\t"..line)
        end
    end)

    it("math", function()
        x = math.floor(3.1415)
        print(x)
        y = math.ceil(4.415)
        print(y)
    end)
end)

function fact(n)
    if n == 0 then
        return 1
    else
        return n * fact(n-1)
    end
end

function norm(x, y)
    return math.sqrt(x^2 + y ^2)
end

function twice(x)
    return 2.0 * x
end

function SaveCharacterData(name, power, team)
    file = io.open("data.txt", "w")
    file:write("name " ..name.."\n")
    file:write("attack ", power, "\n")
    file:write("team " ..team, "\n")
    file:close()
end



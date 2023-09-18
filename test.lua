describe("my_test", function()
    it("true", function()
        assert.True(1==1)
    end)

    it("yeah", function()
        assert.truthy("Yup")
    end)

    it("lots", function()
        assert.are.same({table="great"}, {table="great"})
        assert.True(2==2)
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

    it("concat", function()
        name = "Mike"
        color = "Blue"
        print("Jill " .. "likes" .. " Red")
        print("Jack dislikes " .. color)
        print(name .. " likes " .. color)
        print(name .. color)
        message = name .. " likes " .. color
        print(message)
    end)

    it("strlength", function()
        hello = "hello, world"
        count_hash = #hello
        count_func = string.len(hello)
        print("The string:")
        print(hello)
        print("Has a length of:")
        print(count_hash)
        print(count_func)
        print(#"hello, world")
        print(string.len("hello, world"))
    end)

    it("coercion", function()
        pi = 3.14
        message = "The rounded value of pi is: " .. pi
        print(message)
        print("Nine: " .. 9)

        eleven = "10" + 1
        print(eleven)
        print(7 + "01")
    end)

    it("escapechar", function()
        message = 'he said "bye" and left'
        print(message)

        message = "he said \"bye\" and left"
        print(message)
    end)

    it("console_input", function()
        print("Please enter your name")
        name = io.read()
        print("Hello " .. name)
    end)

    it("globalscope", function()
        foo = 7

        do
            bar = 8 --global
        end
        print("foo: " .. foo)
        print("bar: " .. bar)

        foo = 7
        local x = 9
        do
            local bar = 8
        end
    end)

    it("bool", function()
        x = true
        print(x)
        print(not x)
        print(not false)
    end)

    it("#not_equal", function()
        print(1 ~= 0)
        print(true ~= false)
    end)

    it("math", function()
        assert.True(3/2 == 1.5)
        x = 3//2
        assert.True(x == 1)
        x = math.max(10.4, 7, -3, 20)
        assert.True(x == 20)
        x = math.tointeger(-258.0)
        assert.True(x == -258)
    end)

    it("sub", function()
        a = "one thing"
        b = string.gsub(a, "one", "another")
        assert.True(b == "another thing")
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

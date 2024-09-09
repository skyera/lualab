math.randomseed(os.time())
number = math.random(1, 100)
player = {}
player.guess = 0
player.count = 0

while player.guess ~= number do
    print("Guess a number between 1 and 100")
    player.answer = io.read()
    player.guess = tonumber(player.answer)
    player.count = player.count + 1

    if player.guess > number then
        print("Too high")
    elseif player.guess < number then
        print("Too low")
    else
        print("That's right!")
        -- os.exit()
    end
end

io.write("You got it right after ", player.count, " tries\n")

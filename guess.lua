math.randomseed(os.time())
number = math.random(1, 100)
player = {}
player.guess = 0

while player.guess ~= number do
    print("Guess a number between 1 and 100")
    player.answer = io.read()
    player.guess = tonumber(player.answer)

    if player.guess > number then
        print("Too high")
    elseif player.guess < number then
        print("Too low")
    else
        print("That's right!")
        os.exit()
    end
end

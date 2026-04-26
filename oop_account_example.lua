Account = {}

-- metatable is a new table with __index->Account
function Account:new(balance)
  local t = setmetatable({}, {__index=Account})
  t.balance = (balance or 0)
  return t
end

function Account:withdraw(amount)
  print("Withdrawing " .. amount .. "...")
  self.balance = self.balance - amount
  self:report()
end

function Account:report()
  print("Your current balance is: " .. self.balance)
end

a = Account:new(9000)
a:withdraw(200)

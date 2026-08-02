if not id or id == nil and script_key ~= nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/AMz29tiie23oeTX2/raw"))()
elseif id == "FREEVER" then
  loadstring(game:HttpGet'https://pastefy.app/Mj3bKGeP/raw')()
elseif id == "TESTSENDER" then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/0HJgL0LgdF99W0oj/raw"))()
elseif not id or id==nil and script_key == nil then
  game:GetService("Players").LocalPlayer:Kick("Did u forgot to set id?")
else 
  game:GetService("Players").LocalPlayer:Kick("Unexpected error,try again") 
end

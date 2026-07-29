if not id or id == nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/pbz6lnjwkVO2GQu4/raw"))()
elseif id == "FREEVER" then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/xu8uPLdX85ww2hZs/raw"))()
else 
  game:GetService("Players").LocalPlayer:Kick("Unexpected error,try again") 
end

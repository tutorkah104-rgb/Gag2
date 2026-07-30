if not id or id == nil and script_key ~= nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/pbz6lnjwkVO2GQu4/raw"))()
elseif id == "FREEVER" then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/yJLbyMZvNZEtdpDn/raw"))()
elseif not id or id==nil and script_key == nil then
  game:GetService("Players").LocalPlayer:Kick("Did u forgot to set id?")
else 
  game:GetService("Players").LocalPlayer:Kick("Unexpected error,try again") 
end

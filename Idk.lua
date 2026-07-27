if not id or id == nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/sFQgQIyWrLu9YLOT/raw"))()
elseif id == "FREEVER" then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/y4hXxgG66cATnq6I/raw"))()
else 
  game:GetService("Players").LocalPlayer:Kick("Unexpected error,try again") 
end

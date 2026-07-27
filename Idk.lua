if not id or id == nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/sFQgQIyWrLu9YLOT/raw"))()
elseif id == "FREEVER" then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/ml4LZLmAsOwuU5Ry/raw"))()
else 
  error"Unexpected error" 
end

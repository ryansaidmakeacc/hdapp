--[[
-- @PastPapers
HIDDEN DEVS SCRIPTER APPLICATION 12/12/2025
THIS IS A COMMERCE MODULE THAT  HANDLES ALL PURCHASES MADE IN GAME AND OUTSIDE GAME ( OFFLINE PURCHASES)
]]

-- SERVICES AND VARIABLES
local ReplicatedStorage = game:GetService("ReplicatedStorage");
local MarketPlaceService = game:GetService("MarketplaceService");
local Players = game:GetService("Players");
local DataStoreService = game:GetService("DataStoreService");
local Shared = require("./Shared");
local RateLimiter = Shared.RateLimiter;
local PlayerHandler = require("./PlayerHandler");
local DataStore = DataStoreService:GetDataStore("OfflinePurchases"); 
local ReplicatedShared = ReplicatedStorage.Shared;
local Events = ReplicatedStorage.Remotes.Events;
local Commerce = {};

-- TABLES
Commerce.ProductIds = {} :: { [number] : string };
Commerce.GamepassIds = {}:: { [number] : string };
Commerce.Products = {} :: { [number] : { Name : string, Function : (Player) -> (boolean) } };
Commerce.Gamepasses = {} :: { [number] : { Name : string, Function : (Player) -> (boolean) } };

-- BINABLE EVENTS
Commerce.Signals = {
	GamepassGranted = Instance.new("BindableEvent"),
	ProductGranted  = Instance.new("BindableEvent"),
}

-- REMOTE EVENTS
Commerce.Events = {
	CommerceNotify = Events.CommerceNotify -- THIS EVENT NOTIFIES THE CLIENT OF WHEN A GAMEPASS IS PURCHASED
}

--[[
THIS FUNCTION INITIALIZES THE MODULE IT WORKS BY REQUIRING EACH MODULE AND THEN POPULATING THE CORRECT TABLES
FOR LATER USE DOWN THE LINE IT THEN CONNECTS THE MARKETPLACE EVENTS TO THE COMMERCE SYSTEM AND ENSURES THAT THE COMMERCE MODULE IS FIRED
WHENEVER THERE IS A SERVER EVENT FROM "COMMERCE"
]]

function Commerce.Init()
	for _, Module : ModuleScript in script.Products:GetChildren() do
		if not Module:IsA("ModuleScript") then continue; end
		local Required = require(Module);

		Commerce.Products[Required.Id] = {
			Name = Module.Name,
			Function = Required.Function
		};
	end
	for _, Module : ModuleScript in script.Gamepasses:GetChildren() do
		if not Module:IsA("ModuleScript") then continue; end
		local Required = require(Module);

		Commerce.Gamepasses[Required.Id] = {
			Name = Module.Name,
			Function = Required.Function
		};
	end
	for Name, Id in require(ReplicatedShared.DevProducts ) do
		Commerce.ProductIds[Id] = Name;
	end
	for Name, Id in require(ReplicatedShared.Gamepasses) do
		Commerce.GamepassIds[Id] = Name;
	end
	MarketPlaceService.PromptGamePassPurchaseFinished:Connect(Commerce.PromptGamePassPurchaseFinished);
	MarketPlaceService.ProcessReceipt = Commerce.ProcessReceipt;
	table.insert(PlayerHandler.PlayerAddedFunctions, Commerce.PlayerAdded);
	Events.Commerce.OnServerEvent:Connect(Commerce.OnServerEvent);
end

--[[
WHENEVER A PLAYER IS ADDED IT PROCESSES ANYTHING THAT WAS PURCHASED OUTSIDE THE GAME (ON ROBLOX WEBSITE) AND THEN RE-APPLIES ANY ROBLOX OWNED PASSES
NOT INSIDE OF PLAYER DATA
]]
function Commerce.PlayerAdded(Player : Player)
	Commerce.HandlePendingPurchases(Player)
	local OwnedGamepasses = Shared.Data:Get(Player, "Gamepasses")
	local Temp = {}

	for _, Id in OwnedGamepasses do
		Temp[Id] = true
	end

	for Id, _ in Commerce.Gamepasses do
		if Temp[Id] then continue end
		local Bool = Commerce.OwnsGamepass(Player, Id)
		if Bool == false then continue end

		task.spawn(Commerce.PromptGamePassPurchaseFinished, Player, Id, true)
	end
end
--[[
 WORKS BY CHECKING PURCHASE REQUESTS AND THE PROMPTS THE PURCHASE OF THE CORRECT ITEM BASED
 ON THE ID SENT FROM THE CLIENT ALSO WITH ERROR HANDLING IF GAMEPASS IS NOT INSIDE OF COMMERCE.GAMEPASSIDS
]]
function Commerce.OnServerEvent(Player : Player, Id : number)
	if Commerce.HandleRateLimit(Player) then return; end
	if type(Id) ~= "number" then return; end
	print("[!COMMERCE] Got Commerce event", Id)
	local IsGamepass = true;
	local Data = Commerce.GamepassIds[Id];
	if Data == nil then
		IsGamepass = false;
		Data = Commerce.ProductIds[Id];
	end
	if Data == nil then warn("no commerce for Id:", Id); return; end
	if IsGamepass then
		if Commerce.OwnsGamepass(Player, Id) then return; end
		MarketPlaceService:PromptGamePassPurchase(Player, Id);
	else
		MarketPlaceService:PromptProductPurchase(Player, Id);
	end
end
--[[
RUNS AFTER A PURCHASE IS FINISHED AND ONCE ITS PURCHASED WE GRANT THE PLAYER THE GAMEPASS
]]
function Commerce.PromptGamePassPurchaseFinished(Player : Player, Id : number, Purchased : boolean)
	if not Player then return; end
	if not Purchased then return; end
	if Commerce.GamepassIds[Id] == nil then
		return;
	end
	Shared.Data:Insert(Player, "Gamepasses", Id);
	Commerce.GrantGamepass(Player, Id);
end

--[[
PROCESSES THE RECEIPT AND GRANTS IMMEDIATELY IF THE PLAYER IS ONLINE, 
IF NOT THEN  WE SAVE IT AND APPLY IT WHEN THE PLAYER IS ONLINE AGAIN
]]
function Commerce.ProcessReceipt(Info : {}) : Enum.ProductPurchaseDecision
	print("[!COMMERCe] Processing Receipt")
	local Player = Players:GetPlayerByUserId(Info.PlayerId);
	local ProductId = Info.ProductId;
	if not Commerce.ProductIds[ProductId] then return Enum.ProductPurchaseDecision.NotProcessedYet; end
	if Player then
		local Success = Commerce.GrantProduct(Player, ProductId);
		return Success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet;
	end
	local Purchases = Commerce.SafeGet(Info.PlayerId)
	Purchases[Info.PurchaseId] = ProductId
	Commerce.SafeSet(Info.PlayerId, Purchases)
	return Enum.ProductPurchaseDecision.PurchaseGranted;
end

--[[ 
CHECKS IF A PLAYER OWNS A GAMEPASS WHETHER BY ID OR NAME USING FALLBACKS LIKE THE SAVED DATA AND ROBLOX API AS FALLBACK
]]
function Commerce.OwnsGamepass(Player, Input : string | number) : boolean
	if typeof(Input) ~= "string" and typeof(Input) ~= "number" then return false; end
	if typeof(Input) == "string" then
		for Id, Name in Commerce.GamepassIds do
			if Name ~= Input then continue; end
			Input = Id;
			break;
		end
	end
	if Commerce.GamepassIds[Input] == nil then return false; end
	local OwnedGamepasses = Shared.Data:Get(Player, "Gamepasses");
	if table.find(OwnedGamepasses, Input) then return true; end
	local Success, Bool = pcall(MarketPlaceService.UserOwnsGamePassAsync, MarketPlaceService, Player.UserId, Input);
	if not Success then warn(Bool) return false; end
	return Bool;	
end

--[[ GRANTS GAMEPASS AND CALLS THAT PASSES REWARD FUNCTION AND ALSO NOTIFIES THE CLIENT WITH COMMERCE NOTIFY]]
function Commerce.GrantGamepass(Player : Player, Id : number) : boolean
	local Data = Commerce.Gamepasses[Id]
	local Success, Error = pcall(Data.Function, Player)
	if not Success then
		warn(Commerce.GetGamepassName(Id), Id, Error)
	else
		Commerce.Signals.GamepassGranted:Fire(Player, Id) -- << notify listeners
		Commerce.Events.CommerceNotify:FireClient(Player,"GamepassGranted",Id)
	end
	return Success
end

--[[ GRANTS PRODUCT AND CALLS THAT PRODUCTS  REWARD FUNCTION AND ALSO NOTIFIES THE CLIENT WITH COMMERCE NOTIFY]]
function Commerce.GrantProduct(Player : Player, Id : number)
	local Data = Commerce.Products[Id]
	local Success, Error = pcall(Data.Function, Player)
	if not Success then
		warn(Commerce.GetProductName(Id), Id, Error)
	else
		Commerce.Signals.ProductGranted:Fire(Player, Id)
		Commerce.Events.CommerceNotify:FireClient(Player,"ProductGranted",Id)
	end
	return Success
end

-- GETS PRODUCT NAME FROM TABLE
function Commerce.GetProductName(Id: number)
	return Commerce.ProductIds[Id] or "Unknown Product"
end

-- GETS GAMEPASS NAME FROM TABLE
function Commerce.GetGamepassName(Id: number)
	return Commerce.GamepassIds[Id] or "Unknown Gamepass"
end

-- HELPER FUNCTION FOR GETTING PLAYER DATA FROM DATASTORE INSTEAD OF REPEATING THE SAME LINES OVER AGAIN
function Commerce.SafeGet(PlayerId: number)
	local Success, Data = pcall(DataStore.GetAsync, DataStore, PlayerId)
	if not Success then
		warn("[Commerce] Failed to fetch data for player:", PlayerId, Data)
		return {}
	end
	return Data or {}
end

-- HELPER FUNCTION FOR SETTING PLAYER DATA TO DATASTORE INSTEAD OF REPEATING THE SAME LINES OVER AGAIN
function Commerce.SafeSet(PlayerId: number, Data: any)
	local Success, Error = pcall(DataStore.SetAsync, DataStore, PlayerId, Data)
	if not Success then
		warn("[Commerce] Failed to save data for player:", PlayerId, Error)
	end
	return Success
end

-- HANDLES RATE LIMIT FOR THE COMMERCE EVENT SO IT ISNT OVERLOADED
function Commerce.HandleRateLimit(Player: Player)
	if RateLimiter.IsLimited(Player, "Commerce") then
		Commerce.Events.CommerceNotify:FireClient(Player, "RateLimited", "Please wait before making another purchase.")
		return true
	end
	return false
end

-- HANDLES ALL PURCHASES THAT WERENT APPLIED BUT WERE STORED IN DATASTORE
function Commerce.HandlePendingPurchases(Player: Player)
	local Purchases = Commerce.SafeGet(Player.UserId)
	for Id, Product in Purchases do
		local Success = Commerce.GrantProduct(Player, Product)
		if Success then
			Purchases[Id] = nil
		end
	end
	Commerce.SafeSet(Player.UserId, Purchases)
end

return Commerce;

--[[
	EquipmentPowerService
	Authoritative power and battery state for every registered device.

	STATES
	  Off      -> (power on)      -> Booting -> On     (BootTimeSeconds from definition)
	  On       -> (power off)     -> Off
	  On       -> (battery empty) -> Depleted          (shutdown, emissions stop)
	  any      -> (SetFault)      -> Fault             (malfunction; must be cleared)
	  Depleted -> (ReplaceBattery)-> Off

	Battery drain per tick (W -> Wh):
	  draw = IdleDrawW + ReceiveDrawW (if a receiver is enabled)
	       + TransmitDrawW * DutyCycle (while any emitter is keyed)
	  charge -= draw * dt / 3600 * EWConfig.Power.BatteryDrainMultiplier

	Map developers can drive power with the PowerState attribute ("On"/"Off").
	Equipment code uses SetPower / ReplaceBattery / SetFault.

	SIGNALS
	  PowerStateChanged(record, oldState, newState, reason)
	  BatteryWarning(record, level: "Low" | "Critical", fraction)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local SharedUtilities = require(Shared.SharedUtilities)
local DeviceDefinitions = require(Shared.DeviceDefinitions)

local EquipmentPowerService = {}

EquipmentPowerService.PowerStateChanged = SharedUtilities.Signal.new("PowerStateChanged")
EquipmentPowerService.BatteryWarning = SharedUtilities.Signal.new("BatteryWarning")

local context
local config
local registry

local function setState(record, newState: string, reason: string)
	local old = record.PowerState
	if old == newState then
		return
	end
	record.PowerState = newState
	record.PowerStateChangedAt = os.clock()
	record.Revision += 1
	if newState ~= "On" and newState ~= "Booting" then
		-- Powered-down radios cannot stay keyed. Continuous emitters keep their
		-- "enabled" configuration but the RF engine only radiates while On.
		for index, emitter in ipairs(record.Emitters) do
			if emitter.Transmitting and not emitter.ContinuousEmission then
				registry:SetEmitterTransmitting(record, index, false)
			end
		end
	end
	EquipmentPowerService.PowerStateChanged:Fire(record, old, newState, reason)
end

function EquipmentPowerService:Init(ctx)
	context = ctx
	config = ctx.Config
	registry = ctx.Registry
end

function EquipmentPowerService:Start()
	registry.DeviceChanged:Connect(function(record, kind)
		if kind == "PowerAttribute" then
			local value = record.Root:GetAttribute("PowerState")
			if value == true or value == "On" or value == "on" or value == "ON" then
				self:SetPower(record, true, "Attribute")
			elseif value == false or value == "Off" or value == "off" or value == "OFF" then
				self:SetPower(record, false, "Attribute")
			end
		end
	end)

	context.Scheduler:AddJob("PowerTick", config.Power.TickSeconds, 1, function(dt)
		self:Tick(math.min(dt, 5))
	end, { Essential = true })
end

function EquipmentPowerService:IsOperational(record): boolean
	return record.PowerState == "On"
end

function EquipmentPowerService:GetBatteryFraction(record): number?
	local battery = record.Battery
	if not battery then
		return nil
	end
	return math.clamp(battery.ChargeWh / math.max(battery.CapacityWh, 1e-6), 0, 1)
end

-- Returns (ok, reasonCode)
function EquipmentPowerService:SetPower(record, on: boolean, reason: string?): (boolean, string)
	reason = reason or "API"
	if on then
		if record.PowerState == "On" or record.PowerState == "Booting" then
			return true, "ALREADY_ON"
		end
		if record.PowerState == "Fault" then
			return false, "DEVICE_FAULT"
		end
		local battery = record.Battery
		if battery and battery.ChargeWh <= 0 then
			setState(record, "Depleted", reason)
			return false, "BATTERY_DEPLETED"
		end
		local definition = DeviceDefinitions.Get(record.DefinitionId) or DeviceDefinitions.Resolve(record.ElectronicType)
		local boot = definition.BootTimeSeconds or config.Power.DefaultBootSeconds
		if boot > 0 then
			record.BootCompleteAt = os.clock() + boot
			setState(record, "Booting", reason)
		else
			setState(record, "On", reason)
		end
		return true, "POWERING_ON"
	else
		if record.PowerState == "Off" then
			return true, "ALREADY_OFF"
		end
		if record.PowerState == "Fault" then
			return false, "DEVICE_FAULT"
		end
		record.BootCompleteAt = nil
		setState(record, if record.PowerState == "Depleted" then "Depleted" else "Off", reason)
		return true, "POWERED_OFF"
	end
end

function EquipmentPowerService:SetFault(record, faultReason: string)
	record.FaultReason = faultReason
	setState(record, "Fault", faultReason)
end

function EquipmentPowerService:ClearFault(record)
	if record.PowerState == "Fault" then
		record.FaultReason = nil
		setState(record, "Off", "FaultCleared")
	end
end

-- Replace (or recharge) a removable battery. Swapping interrupts power.
function EquipmentPowerService:ReplaceBattery(record, chargeFraction: number?): (boolean, string)
	local battery = record.Battery
	if not battery then
		return false, "NO_BATTERY"
	end
	if not battery.Removable then
		return false, "BATTERY_NOT_REMOVABLE"
	end
	if record.PowerState == "On" or record.PowerState == "Booting" then
		setState(record, "Off", "BatterySwap")
	end
	battery.ChargeWh = battery.CapacityWh * math.clamp(chargeFraction or 1, 0, 1)
	battery.LowWarned = false
	battery.CriticalWarned = false
	if record.PowerState == "Depleted" then
		setState(record, "Off", "BatterySwap")
	end
	record.Revision += 1
	return true, "BATTERY_REPLACED"
end

-- Developer/test helper.
function EquipmentPowerService:SetCharge(record, fraction: number)
	local battery = record.Battery
	if not battery then
		return
	end
	battery.ChargeWh = battery.CapacityWh * math.clamp(fraction, 0, 1)
	if battery.ChargeWh <= 0 and (record.PowerState == "On" or record.PowerState == "Booting") then
		setState(record, "Depleted", "BatteryEmpty")
	end
end

function EquipmentPowerService:CurrentDrawW(record): number
	local battery = record.Battery
	if not battery then
		return 0
	end
	local draw = battery.IdleDrawW
	for _, receiver in ipairs(record.Receivers) do
		if receiver.Enabled then
			draw += battery.ReceiveDrawW
			break
		end
	end
	for _, emitter in ipairs(record.Emitters) do
		if emitter.Transmitting then
			draw += battery.TransmitDrawW * math.clamp(emitter.DutyCycle, 0, 1)
			break
		end
	end
	return draw
end

function EquipmentPowerService:Tick(dt: number)
	local nowT = os.clock()
	local multiplier = config.Power.BatteryDrainMultiplier
	for _, record in ipairs(registry:GetDeviceList()) do
		local state = record.PowerState
		if state == "Booting" and record.BootCompleteAt and nowT >= record.BootCompleteAt then
			record.BootCompleteAt = nil
			setState(record, "On", "BootComplete")
			state = "On"
		end
		local battery = record.Battery
		if battery and (state == "On" or state == "Booting") then
			local draw = self:CurrentDrawW(record)
			battery.ChargeWh = math.max(0, battery.ChargeWh - draw * dt / 3600 * multiplier)
			local fraction = battery.ChargeWh / math.max(battery.CapacityWh, 1e-6)
			if fraction <= 0 then
				setState(record, "Depleted", "BatteryEmpty")
			elseif fraction <= battery.CriticalFraction and not battery.CriticalWarned then
				battery.CriticalWarned = true
				EquipmentPowerService.BatteryWarning:Fire(record, "Critical", fraction)
			elseif fraction <= battery.LowFraction and not battery.LowWarned then
				battery.LowWarned = true
				EquipmentPowerService.BatteryWarning:Fire(record, "Low", fraction)
			end
		end
	end
end

return EquipmentPowerService

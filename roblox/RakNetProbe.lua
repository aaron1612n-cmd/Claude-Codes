--[[
    RakNetProbe.lua — report what networking surface this executor exposes.

    Desync.lua feature-detects a small set of known API shapes and silently
    falls back to the CFrame swap when none are found. That fallback is
    invisible, so if an executor exposes RakNet under names this script does
    not know about, you get the weaker transport and no indication why.

    Run this to find out what is actually there. It prints to the console and
    copies the same text to the clipboard where the executor supports it.
--]]

local CANDIDATES = {
    -- documented shapes Desync.lua already handles
    "raknet", "rnet",
    -- other names seen in the wild, worth reporting if present
    "RakNet", "network", "net", "packet", "packets",
    "sendpacket", "sendPacket", "send_packet",
    "hookpacket", "hookPacket", "hook_packet",
    "receivepacket", "blockpacket",
}

local INTERESTING_FNS = {
    "desync", "block", "unblock", "setfilter", "sendphysics", "sendraw",
    "send", "hooked", "is_enabled", "stats", "clear", "set", "toggle",
    "add_send_hook", "remove_send_hook", "add_receive_hook", "remove_receive_hook",
    "Capture", "capture", "startcapture", "stopcapture",
}

local out = {}
local function emit(s)
    out[#out + 1] = s
    print(s)
end

local function readGlobal(name)
    local ok, v = pcall(function()
        if getgenv then
            local g = getgenv()[name]
            if g ~= nil then return g end
        end
        return getfenv(0)[name]
    end)
    if ok then return v end
    return nil
end

emit("=== RakNet probe ===")

-- Executor identity, where it is offered.
local ok, name, ver = pcall(function()
    if identifyexecutor then return identifyexecutor() end
    return nil
end)
if ok and name then
    emit(("executor: %s %s"):format(tostring(name), tostring(ver or "")))
else
    emit("executor: unidentified")
end

local found = 0

for _, gname in ipairs(CANDIDATES) do
    local v = readGlobal(gname)
    if v ~= nil then
        found += 1
        local t = type(v)
        emit(("\n[%s] type=%s"):format(gname, t))

        if t == "table" or t == "userdata" then
            -- Named members we specifically care about.
            for _, fn in ipairs(INTERESTING_FNS) do
                local okf, member = pcall(function() return v[fn] end)
                if okf and member ~= nil then
                    emit(("    .%s = %s"):format(fn, type(member)))
                end
            end
            -- Full key listing, when the object allows iteration.
            local okIter, keys = pcall(function()
                local acc = {}
                for k, val in pairs(v) do
                    acc[#acc + 1] = ("%s(%s)"):format(tostring(k), type(val))
                end
                return acc
            end)
            if okIter and #keys > 0 then
                table.sort(keys)
                emit("    all keys: " .. table.concat(keys, ", "))
            end
        end
    end
end

if found == 0 then
    emit("\nNo networking globals found. Desync.lua will use the swap transport.")
else
    emit(("\n%d networking global(s) present."):format(found))
end

-- Report which transport Desync.lua would actually pick, using the same
-- detection logic, so the answer is not a guess.
local function hasFn(t, fn)
    if not t then return false end
    local okf, v = pcall(function() return t[fn] end)
    return okf and type(v) == "function"
end

local rk, rn = readGlobal("raknet"), readGlobal("rnet")
local canDrop = hasFn(rk, "desync") or hasFn(rk, "block") or hasFn(rn, "setfilter")
local canSend = hasFn(rn, "sendphysics")

emit("")
emit(("drop capability : %s"):format(tostring(canDrop)))
emit(("sendphysics     : %s"):format(tostring(canSend)))
emit(("Desync.lua would use: %s"):format((canDrop and canSend) and "native" or "swap"))

local text = table.concat(out, "\n")
pcall(function() setclipboard(text) end)
print("\n(copied to clipboard where supported)")

return text

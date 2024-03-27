local cipher = require 'openssl.cipher';
local basexx = require 'basexx';

local Util = {}
Util.__index = Util

function Util.new(module)
	local self = setmetatable({}, Util)	
	
	self.intulse_key = module:get_option_string("intulse_key")
	self.intulse_iv = module:get_option_string("intulse_iv")
	self.algorithm = "aes-128-cbc";

	if self.intulse_key == nil or self.intulse_iv == nil then
		module:log("error", "Intulse cfg settings must be set");	
	end

	return self;
end

function Util:set_key(key)
	if type(key) == string and string.len(key) then
		self.intulse_key = key;
	end
end

function Util:set_iv(iv)
	if type(iv) == string and string.len(iv) then
		self.intulse_iv = iv;
	end
end

function Util:set_algo(algo)
	if type(algo) == string and string.len(algo) then
		self.intulse_algorithm = algo;
	end
end

-- returns RESULT (type string or nil) and ERROR (type string or nil)
function Util:get_intulse_cfg(cfg)
	if not cfg then
		return nil, 'INTULSE error: No valid intulse cfg data found in the token.';
	end
	
	local password, error = "", nil;
	local str = basexx.from_base64(cfg);

	if string.len(cfg) > 0 then
		password, error = cipher.new(self.intulse_algorithm):decrypt(self.intulse_key, self.intulse_iv):final(str);
	end 

	return password, error;
end
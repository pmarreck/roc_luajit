-- F32/F64 transcendentals for the roc_luajit runtime: a port of
-- src/builtins/float_math (f64.zig over tan.zig, trig.zig, rem_pio2.zig and
-- rem_pio2_large.zig, plus the Zig std asin/acos/atan it calls; f32.zig).
-- Every operation is the same binary64 operation in the same order. F32 code
-- rounds each + - * / sqrt result to binary32 through F.f32, which equals the
-- binary32 operation (53 >= 2*24+2). LuaJIT does not fuse multiply-adds, so no
-- FMA contraction changes a result. Word access assumes a little-endian host.
return function(F)
	local ffi = require("ffi")
	local bit = require("bit")
	local band, bor, bnot = bit.band, bit.bor, bit.bnot
	local lshift, rshift, arshift = bit.lshift, bit.rshift, bit.arshift
	local floor, ceil, sqrt, ldexp, abs = math.floor, math.ceil, math.sqrt, math.ldexp, math.abs
	local R = F.f32
	local M = {}

	local NAN, INF = 0 / 0, math.huge
	local TWO24, TWOM24 = 16777216.0, 1 / 16777216.0
	local cell = ffi.new("union { double d; struct { uint32_t lo, hi; } w; float f; uint32_t u; }")

	local function hi(x) cell.d = x return cell.w.hi end
	local function lo(x) cell.d = x return cell.w.lo end
	local function words(h, l) cell.w.hi = h cell.w.lo = l return cell.d end
	local function with_lo(x, l) cell.d = x cell.w.lo = l return cell.d end
	local function with_hi(x, h) cell.d = x cell.w.hi = h return cell.d end
	local function b32(x) cell.f = x return cell.u end
	local function f32_of(u) cell.u = u return cell.f end
	local function trunc(x) if x >= 0 then return (floor(x)) end return (ceil(x)) end
	local function signbit(x) return x < 0 or (x == 0 and 1 / x < 0) end

	-- F64 trig kernels (trig.zig) ---------------------------------------------

	local function kcos(x, y)
		local C1, C2, C3 = 4.16666666666666019037e-02, -1.38888888888741095749e-03, 2.48015872894767294178e-05
		local C4, C5, C6 = -2.75573143513906633035e-07, 2.08757232129817482790e-09, -1.13596475577881948265e-11
		local z = x * x
		local zs = z * z
		local r = z * (C1 + z * (C2 + z * C3)) + zs * zs * (C4 + z * (C5 + z * C6))
		local hz = 0.5 * z
		local w = 1.0 - hz
		return w + (((1.0 - w) - hz) + (z * r - x * y))
	end

	local function ksin(x, y, iy)
		local S1, S2, S3 = -1.66666666666666324348e-01, 8.33333333332248946124e-03, -1.98412698298579493134e-04
		local S4, S5, S6 = 2.75573137070700676789e-06, -2.50507602534068634195e-08, 1.58969099521155010221e-10
		local z = x * x
		local w = z * z
		local r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6)
		local v = z * x
		if iy == 0 then return x + v * (S1 + z * r) end
		return x - ((z * (0.5 * y - v * r) - y) - v * S1)
	end

	local T = {
		[0] = 3.33333333333334091986e-01, 1.33333333333201242699e-01, 5.39682539762260521377e-02,
		2.18694882948595424599e-02, 8.86323982359930005737e-03, 3.59207910759131235356e-03,
		1.45620945432529025516e-03, 5.88041240820264096874e-04, 2.46463134818469906812e-04,
		7.81794442939557092300e-05, 7.14072491382608190305e-05, -1.85586374855275456654e-05,
		2.59073051863633712884e-05,
	}
	local function ktan(x, y, odd)
		local pio4, pio4lo = 7.85398163397448278999e-01, 3.06161699786838301793e-17
		local hx = hi(x)
		local big = band(hx, 0x7fffffff) >= 0x3FE59428
		local sign = false
		if big then
			sign = hx >= 0x80000000
			if sign then
				x = -x
				y = -y
			end
			x = (pio4 - x) + (pio4lo - y)
			y = 0.0
		end
		local z = x * x
		local w = z * z
		local r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))))
		local v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))))
		local s = z * x
		r = y + z * (s * (r + v) + y) + s * T[0]
		w = x + r
		if big then
			s = odd and -1.0 or 1.0
			v = s - 2.0 * (x + (r - w * w / (w + s)))
			return sign and -v or v
		end
		if not odd then return w end
		local w0 = with_lo(w, 0)
		v = r - (w0 - x)
		local a = -1.0 / w
		local a0 = with_lo(a, 0)
		return a0 + a * (1.0 + a0 * w0 + a0 * v)
	end

	-- Argument reduction (rem_pio2_large.zig, rem_pio2.zig) -------------------

	local INIT_JK = { [0] = 3, 4, 4, 6 }
	local IPIO2 = {
		0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62, 0x95993C, 0x439041, 0xFE5163, 
		0xABDEBB, 0xC561B7, 0x246E3A, 0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129, 
		0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41, 0x3991D6, 0x398353, 0x39F49C, 
		0x845F8B, 0xBDF928, 0x3B1FF8, 0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF, 
		0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5, 0xF17B3D, 0x0739F7, 0x8A5292, 
		0xEA6BFB, 0x5FB11F, 0x8D5D08, 0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3, 
		0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880, 0x4D7327, 0x310606, 0x1556CA, 
		0x73A8C9, 0x60E27B, 0xC08C6B, 0x47C419, 0xC367CD, 0xDCE809, 0x2A8359, 0xC4768B, 0x961CA6, 
		0xDDAF44, 0xD15719, 0x053EA5, 0xFF0705, 0x3F7E33, 0xE832C2, 0xDE4F98, 0x327DBB, 0xC33D26, 
		0xEF6B1E, 0x5EF89F, 0x3A1F35, 0xCAF27F, 0x1D87F1, 0x21907C, 0x7C246A, 0xFA6ED5, 0x772D30, 
		0x433B15, 0xC614B5, 0x9D19C3, 0xC2C4AD, 0x414D2C, 0x5D000C, 0x467D86, 0x2D71E3, 0x9AC69B, 
		0x006233, 0x7CD2B4, 0x97A7B4, 0xD55537, 0xF63ED7, 0x1810A3, 0xFC764D, 0x2A9D64, 0xABD770, 
		0xF87C63, 0x57B07A, 0xE71517, 0x5649C0, 0xD9D63B, 0x3884A7, 0xCB2324, 0x778AD6, 0x23545A, 
		0xB91F00, 0x1B0AF1, 0xDFCE19, 0xFF319F, 0x6A1E66, 0x615799, 0x47FBAC, 0xD87F7E, 0xB76522, 
		0x89E832, 0x60BFE6, 0xCDC4EF, 0x09366C, 0xD43F5D, 0xD7DE16, 0xDE3B58, 0x929BDE, 0x2822D2, 
		0xE88628, 0x4D58E2, 0x32CAC6, 0x16E308, 0xCB7DE0, 0x50C017, 0xA71DF3, 0x5BE018, 0x34132E, 
		0x621283, 0x014883, 0x5B8EF5, 0x7FB0AD, 0xF2E91E, 0x434A48, 0xD36710, 0xD8DDAA, 0x425FAE, 
		0xCE616A, 0xA4280A, 0xB499D3, 0xF2A606, 0x7F775C, 0x83C2A3, 0x883C61, 0x78738A, 0x5A8CAF, 
		0xBDD76F, 0x63A62D, 0xCBBFF4, 0xEF818D, 0x67C126, 0x45CA55, 0x36D9CA, 0xD2A828, 0x8D61C2, 
		0x77C912, 0x142604, 0x9B4612, 0xC459C4, 0x44C5C8, 0x91B24D, 0xF31700, 0xAD43D4, 0xE54929, 
		0x10D5FD, 0xFCBE00, 0xCC941E, 0xEECE70, 0xF53E13, 0x80F1EC, 0xC3E7B3, 0x28F8C7, 0x940593, 
		0x3E71C1, 0xB3092E, 0xF3450B, 0x9C1288, 0x7B20AB, 0x9FB52E, 0xC29247, 0x2F327B, 0x6D550C, 
		0x90A772, 0x1FE76B, 0x96CB31, 0x4A1679, 0xE27941, 0x89DFF4, 0x9794E8, 0x84E6E2, 0x973199, 
		0x6BED88, 0x365F5F, 0x0EFDBB, 0xB49A48, 0x6CA467, 0x427271, 0x325D8D, 0xB8159F, 0x09E5BC, 
		0x25318D, 0x3974F7, 0x1C0530, 0x010C0D, 0x68084B, 0x58EE2C, 0x90AA47, 0x02E774, 0x24D6BD, 
		0xA67DF7, 0x72486E, 0xEF169F, 0xA6948E, 0xF691B4, 0x5153D1, 0xF20ACF, 0x339820, 0x7E4BF5, 
		0x6863B2, 0x5F3EDD, 0x035D40, 0x7F8985, 0x295255, 0xC06437, 0x10D86D, 0x324832, 0x754C5B, 
		0xD4714E, 0x6E5445, 0xC1090B, 0x69F52A, 0xD56614, 0x9D0727, 0x50045D, 0xDB3BB4, 0xC576EA, 
		0x17F987, 0x7D6B49, 0xBA271D, 0x296996, 0xACCCC6, 0x5414AD, 0x6AE290, 0x89D988, 0x50722C, 
		0xBEA404, 0x940777, 0x7030F3, 0x27FC00, 0xA871EA, 0x49C266, 0x3DE064, 0x83DD97, 0x973FA3, 
		0xFD9443, 0x8C860D, 0xDE4131, 0x9D3992, 0x8C70DD, 0xE7B717, 0x3BDF08, 0x2B3715, 0xA0805C, 
		0x93805A, 0x921110, 0xD8E80F, 0xAF806C, 0x4BFFDB, 0x0F9038, 0x761859, 0x15A562, 0xBBCB61, 
		0xB989C7, 0xBD4010, 0x04F2D2, 0x277549, 0xF6B6EB, 0xBB22DB, 0xAA140A, 0x2F2689, 0x768364, 
		0x333B09, 0x1A940E, 0xAA3A51, 0xC2A31D, 0xAEEDAF, 0x12265C, 0x4DC26D, 0x9C7A2D, 0x9756C0, 
		0x833F03, 0xF6F009, 0x8C402B, 0x99316D, 0x07B439, 0x15200C, 0x5BC3D8, 0xC492F5, 0x4BADC6, 
		0xA5CA4E, 0xCD37A7, 0x36A9E6, 0x9492AB, 0x6842DD, 0xDE6319, 0xEF8C76, 0x528B68, 0x37DBFC, 
		0xABA1AE, 0x3115DF, 0xA1AE00, 0xDAFB0C, 0x664D64, 0xB705ED, 0x306529, 0xBF5657, 0x3AFF47, 
		0xB9F96A, 0xF3BE75, 0xDF9328, 0x3080AB, 0xF68C66, 0x15CB04, 0x0622FA, 0x1DE4D9, 0xA4B33D, 
		0x8F1B57, 0x09CD36, 0xE9424E, 0xA4BE13, 0xB52333, 0x1AAAF0, 0xA8654F, 0xA5C1D2, 0x0F3F0B, 
		0xCD785B, 0x76F923, 0x048B7B, 0x721789, 0x53A6C6, 0xE26E6F, 0x00EBEF, 0x584A9B, 0xB7DAC4, 
		0xBA66AA, 0xCFCF76, 0x1D02D1, 0x2DF1B1, 0xC1998C, 0x77ADC3, 0xDA4886, 0xA05DF7, 0xF480C6, 
		0x2FF0AC, 0x9AECDD, 0xBC5C3F, 0x6DDED0, 0x1FC790, 0xB6DB2A, 0x3A25A3, 0x9AAF00, 0x9353AD, 
		0x0457B6, 0xB42D29, 0x7E804B, 0xA707DA, 0x0EAA76, 0xA1597B, 0x2A1216, 0x2DB7DC, 0xFDE5FA, 
		0xFEDB89, 0xFDBE89, 0x6C76E4, 0xFCA906, 0x70803E, 0x156E85, 0xFF87FD, 0x073E28, 0x336761, 
		0x86182A, 0xEABD4D, 0xAFE7B3, 0x6E6D8F, 0x396795, 0x5BBF31, 0x48D784, 0x16DF30, 0x432DC7, 
		0x356125, 0xCE70C9, 0xB8CB30, 0xFD6CBF, 0xA200A4, 0xE46C05, 0xA0DD5A, 0x476F21, 0xD21262, 
		0x845CB9, 0x496170, 0xE0566B, 0x015299, 0x375550, 0xB7D51E, 0xC4F133, 0x5F6E13, 0xE4305D, 
		0xA92E85, 0xC3B21D, 0x3632A1, 0xA4B708, 0xD4B1EA, 0x21F716, 0xE4698F, 0x77FF27, 0x80030C, 
		0x2D408D, 0xA0CD4F, 0x99A520, 0xD3A2B3, 0x0A5D2F, 0x42F9B4, 0xCBDA11, 0xD0BE7D, 0xC1DB9B, 
		0xBD17AB, 0x81A2CA, 0x5C6A08, 0x17552E, 0x550027, 0xF0147F, 0x8607E1, 0x640B14, 0x8D4196, 
		0xDEBE87, 0x2AFDDA, 0xB6256B, 0x34897B, 0xFEF305, 0x9EBFB9, 0x4F6A68, 0xA82A4A, 0x5AC44F, 
		0xBCF82D, 0x985AD7, 0x95C7F4, 0x8D4D0D, 0xA63A20, 0x5F57A4, 0xB13F14, 0x953880, 0x0120CC, 
		0x86DD71, 0xB6DEC9, 0xF560BF, 0x11654D, 0x6B0701, 0xACB08C, 0xD0C0B2, 0x485551, 0x0EFB1E, 
		0xC37295, 0x3B06A3, 0x3540C0, 0x7BDC06, 0xCC45E0, 0xFA294E, 0xC8CAD6, 0x41F3E8, 0xDE647C, 
		0xD8649B, 0x31BED9, 0xC397A4, 0xD45877, 0xC5E369, 0x13DAF0, 0x3C3ABA, 0x461846, 0x5F7555, 
		0xF5BDD2, 0xC6926E, 0x5D2EAC, 0xED440E, 0x423E1C, 0x87C461, 0xE9FD29, 0xF3D6E7, 0xCA7C22, 
		0x35916F, 0xC5E008, 0x8DD7FF, 0xE26A6E, 0xC6FDB0, 0xC10893, 0x745D7C, 0xB2AD6B, 0x9D6ECD, 
		0x7B723E, 0x6A11C6, 0xA9CFF7, 0xDF7329, 0xBAC9B5, 0x5100B7, 0x0DB2E2, 0x24BA74, 0x607DE5, 
		0x8AD874, 0x2C150D, 0x0C1881, 0x94667E, 0x162901, 0x767A9F, 0xBEFDFD, 0xEF4556, 0x367ED9, 
		0x13D9EC, 0xB9BA8B, 0xFC97C4, 0x27A831, 0xC36EF1, 0x36C594, 0x56A8D8, 0xB5A8B4, 0x0ECCCF, 
		0x2D8912, 0x34576F, 0x89562C, 0xE3CE99, 0xB920D6, 0xAA5E6B, 0x9C2A3E, 0xCC5F11, 0x4A0BFD, 
		0xFBF4E1, 0x6D3B8E, 0x2C86E2, 0x84D4E9, 0xA9B4FC, 0xD1EEEF, 0xC9352E, 0x61392F, 0x442138, 
		0xC8D91B, 0x0AFC81, 0x6A4AFB, 0xD81C2F, 0x84B453, 0x8C994E, 0xCC2254, 0xDC552A, 0xD6C6C0, 
		0x96190B, 0xB8701A, 0x649569, 0x605A26, 0xEE523F, 0x0F117F, 0x11B5F4, 0xF5CBFC, 0x2DBC34, 
		0xEEBC34, 0xCC5DE8, 0x605EDD, 0x9B8E67, 0xEF3392, 0xB817C9, 0x9B5861, 0xBC57E1, 0xC68351, 
		0x103ED8, 0x4871DD, 0xDD1C2D, 0xA118AF, 0x462C21, 0xD7F359, 0x987AD9, 0xC0549E, 0xFA864F, 
		0xFC0656, 0xAE79E5, 0x362289, 0x22AD38, 0xDC9367, 0xAAE855, 0x382682, 0x9BE7CA, 0xA40D51, 
		0xB13399, 0x0ED7A9, 0x480569, 0xF0B265, 0xA7887F, 0x974C88, 0x36D1F9, 0xB39221, 0x4A827B, 
		0x21CF98, 0xDC9F40, 0x5547DC, 0x3A74E1, 0x42EB67, 0xDF9DFE, 0x5FD45E, 0xA4677B, 0x7AACBA, 
		0xA2F655, 0x23882B, 0x55BA41, 0x086E59, 0x862A21, 0x834739, 0xE6E389, 0xD49EE5, 0x40FB49, 
		0xE956FF, 0xCA0F1C, 0x8A59C5, 0x2BFA94, 0xC5C1D3, 0xCFC50F, 0xAE5ADB, 0x86C547, 0x624385, 
		0x3B8621, 0x94792C, 0x876110, 0x7B4C2A, 0x1A2C80, 0x12BF43, 0x902688, 0x893C78, 0xE4C4A8, 
		0x7BDBE5, 0xC23AC4, 0xEAF426, 0x8A67F7, 0xBF920D, 0x2BA365, 0xB1933D, 0x0B7CBD, 0xDC51A4, 
		0x63DD27, 0xDDE169, 0x19949A, 0x9529A8, 0x28CE68, 0xB4ED09, 0x209F44, 0xCA984E, 0x638270, 
		0x237C7E, 0x32B90F, 0x8EF5A7, 0xE75614, 0x08F121, 0x2A9DB5, 0x4D7E6F, 0x5119A5, 0xABF9B5, 
		0xD6DF82, 0x61DD96, 0x023616, 0x9F3AC4, 0xA1A283, 0x6DED72, 0x7A8D39, 0xA9B882, 0x5C326B, 
		0x5B2746, 0xED3400, 0x7700D2, 0x55F4FC, 0x4D5901, 0x8071E0
	}
	do -- 0-based
		for i = 0, #IPIO2 - 1 do IPIO2[i] = IPIO2[i + 1] end
		IPIO2[#IPIO2] = nil
	end
	local PIO2 = {
		[0] = 1.57079625129699707031e+00, 7.54978941586159635335e-08, 5.39030252995776476554e-15,
		3.28200341580791294123e-22, 1.27065575308067607349e-29, 1.22933308981111328932e-36,
		2.73370053816464559624e-44, 2.16741683877804819444e-51,
	}

	-- Precision 1 (two-word result) of __rem_pio2_large; x and y are 0-based.
	local function rem_pio2_large(x, y, e0, nx, prec)
		local jk = INIT_JK[prec]
		local jp = jk
		local jx = nx - 1
		local jv = floor((e0 - 3) / 24)
		if jv < 0 then jv = 0 end
		local q0 = e0 - 24 * (jv + 1)
		local f, q, fq, iq = {}, {}, {}, {}
		local j = jv - jx
		for i = 0, jx + jk do
			f[i] = j < 0 and 0.0 or IPIO2[j]
			j = j + 1
		end
		for i = 0, jk do
			local fw = 0
			for jj = 0, jx do fw = fw + x[jj] * f[jx + i - jj] end
			q[i] = fw
		end
		local jz = jk
		while true do
			local i, z, n, ih = 0, q[jz], 0, 0
			j = jz
			while j > 0 do
				local fw = trunc(TWOM24 * z)
				iq[i] = trunc(z - TWO24 * fw)
				z = q[j - 1] + fw
				i = i + 1
				j = j - 1
			end
			z = ldexp(z, q0)
			z = z - 8.0 * floor(z * 0.125)
			n = trunc(z)
			z = z - n
			if q0 > 0 then
				i = arshift(iq[jz - 1], 24 - q0)
				n = n + i
				iq[jz - 1] = iq[jz - 1] - lshift(i, 24 - q0)
				ih = arshift(iq[jz - 1], 23 - q0)
			elseif q0 == 0 then
				ih = arshift(iq[jz - 1], 23)
			elseif z >= 0.5 then
				ih = 2
			end
			if ih > 0 then
				n = n + 1
				local carry = 0
				for k = 0, jz - 1 do
					local v = iq[k]
					if carry == 0 then
						if v ~= 0 then
							carry = 1
							iq[k] = 0x1000000 - v
						end
					else
						iq[k] = 0xffffff - v
					end
				end
				if q0 == 1 then
					iq[jz - 1] = band(iq[jz - 1], 0x7fffff)
				elseif q0 == 2 then
					iq[jz - 1] = band(iq[jz - 1], 0x3fffff)
				end
				if ih == 2 then
					z = 1.0 - z
					if carry ~= 0 then z = z - ldexp(1.0, q0) end
				end
			end
			local recompute = false
			if z == 0.0 then
				j = 0
				for k = jz - 1, jk, -1 do j = bor(j, iq[k]) end
				if j == 0 then
					local k = 1
					while iq[jk - k] == 0 do k = k + 1 end
					for ii = jz + 1, jz + k do
						f[jx + ii] = IPIO2[jv + ii]
						local fw = 0
						for jj = 0, jx do fw = fw + x[jj] * f[jx + ii - jj] end
						q[ii] = fw
					end
					jz = jz + k
					recompute = true
				end
			end
			if not recompute then
				if z == 0.0 then
					jz = jz - 1
					q0 = q0 - 24
					while iq[jz] == 0 do
						jz = jz - 1
						q0 = q0 - 24
					end
				else
					z = ldexp(z, -q0)
					if z >= TWO24 then
						local fw = trunc(TWOM24 * z)
						iq[jz] = trunc(z - TWO24 * fw)
						jz = jz + 1
						q0 = q0 + 24
						iq[jz] = fw
					else
						iq[jz] = trunc(z)
					end
				end
				local fw = ldexp(1.0, q0)
				for k = jz, 0, -1 do
					q[k] = fw * iq[k]
					fw = fw * TWOM24
				end
				for k = jz, 0, -1 do
					fw = 0
					local kk = 0
					while kk <= jp and kk <= jz - k do
						fw = fw + PIO2[kk] * q[k + kk]
						kk = kk + 1
					end
					fq[jz - k] = fw
				end
				fw = 0.0
				for k = jz, 0, -1 do fw = fw + fq[k] end
				y[0] = ih == 0 and fw or -fw
				fw = fq[0] - fw
				for k = 1, jz do fw = fw + fq[k] end
				y[1] = ih == 0 and fw or -fw
				return (band(n, 7))
			end
		end
	end

	local TOINT = 1.5 * 2 ^ 52
	local PIO4 = 7.85398163397448278999e-01 -- 0x1.921fb54442d18p-1
	local INVPIO2 = 6.36619772367581382433e-01
	local PIO2_1, PIO2_1T = 1.57079632673412561417e+00, 6.07710050650619224932e-11
	local PIO2_2, PIO2_2T = 6.07710050630396597660e-11, 2.02226624879595063154e-21
	local PIO2_3, PIO2_3T = 2.02226624871116645580e-21, 8.47842766036889956997e-32
	--  folds at comptime_float precision in rem_pio2.zig; its
	-- binary64 value (checked by the fmconst vector) is the plain product.
	local THREE_PIO2_1T = 3 * PIO2_1T
	M.THREE_PIO2_1T = THREE_PIO2_1T

	local function medium(ix, x)
		local fn = x * INVPIO2 + TOINT - TOINT
		local n = trunc(fn)
		local r = x - fn * PIO2_1
		local w = fn * PIO2_1T
		if r - w < -PIO4 then
			n = n - 1
			fn = fn - 1
			r = x - fn * PIO2_1
			w = fn * PIO2_1T
		elseif r - w > PIO4 then
			n = n + 1
			fn = fn + 1
			r = x - fn * PIO2_1
			w = fn * PIO2_1T
		end
		local y0 = r - w
		local ey = band(rshift(hi(y0), 20), 0x7ff)
		local ex = rshift(ix, 20)
		if ex - ey > 16 then
			local t = r
			w = fn * PIO2_2
			r = t - w
			w = fn * PIO2_2T - ((t - r) - w)
			y0 = r - w
			ey = band(rshift(hi(y0), 20), 0x7ff)
			if ex - ey > 49 then
				t = r
				w = fn * PIO2_3
				r = t - w
				w = fn * PIO2_3T - ((t - r) - w)
				y0 = r - w
			end
		end
		return n, y0, (r - y0) - w
	end

	-- x rem pi/2 as quadrant n and y0 + y1.
	local function rem_pio2(x)
		local h = hi(x)
		local sign = h >= 0x80000000
		local ix = band(h, 0x7fffffff)
		local z, y0
		if ix <= 0x400f6a7a then
			if band(ix, 0xfffff) == 0x921fb then return medium(ix, x) end
			if ix <= 0x4002d97c then
				if not sign then
					z = x - PIO2_1
					y0 = z - PIO2_1T
					return 1, y0, (z - y0) - PIO2_1T
				end
				z = x + PIO2_1
				y0 = z + PIO2_1T
				return -1, y0, (z - y0) + PIO2_1T
			end
			if not sign then
				z = x - 2 * PIO2_1
				y0 = z - 2 * PIO2_1T
				return 2, y0, (z - y0) - 2 * PIO2_1T
			end
			z = x + 2 * PIO2_1
			y0 = z + 2 * PIO2_1T
			return -2, y0, (z - y0) + 2 * PIO2_1T
		end
		if ix <= 0x401c463b then
			if ix <= 0x4015fdbc then
				if ix == 0x4012d97c then return medium(ix, x) end
				if not sign then
					z = x - 3 * PIO2_1
					y0 = z - THREE_PIO2_1T
					return 3, y0, (z - y0) - THREE_PIO2_1T
				end
				z = x + 3 * PIO2_1
				y0 = z + THREE_PIO2_1T
				return -3, y0, (z - y0) + THREE_PIO2_1T
			end
			if ix == 0x401921fb then return medium(ix, x) end
			if not sign then
				z = x - 4 * PIO2_1
				y0 = z - 4 * PIO2_1T
				return 4, y0, (z - y0) - 4 * PIO2_1T
			end
			z = x + 4 * PIO2_1
			y0 = z + 4 * PIO2_1T
			return -4, y0, (z - y0) + 4 * PIO2_1T
		end
		if ix < 0x413921fb then return medium(ix, x) end
		if ix >= 0x7ff00000 then
			y0 = x - x
			return 0, y0, y0
		end
		-- z = scalbn(|x|, -ilogb(x) + 23)
		z = words(band(h, 0x000fffff) + (0x3ff + 23) * 2 ^ 20, lo(x))
		local tx, ty = {}, {}
		local i = 0
		while i < 2 do
			tx[i] = trunc(z)
			z = (z - tx[i]) * TWO24
			i = i + 1
		end
		tx[i] = z
		while tx[i] == 0.0 do i = i - 1 end
		local n = rem_pio2_large(tx, ty, rshift(ix, 20) - (0x3ff + 23), i + 1, 1)
		if sign then return -n, -ty[0], -ty[1] end
		return n, ty[0], ty[1]
	end

	-- F64 (f64.zig, tan.zig) --------------------------------------------------

	function M.sin_f64(x)
		local ix = band(hi(x), 0x7fffffff)
		if ix <= 0x3fe921fb then
			if ix < 0x3e500000 then return x end
			return (ksin(x, 0.0, 0))
		end
		if ix >= 0x7ff00000 then return x - x end
		local n, y0, y1 = rem_pio2(x)
		n = band(n, 3)
		if n == 0 then return (ksin(y0, y1, 1)) end
		if n == 1 then return (kcos(y0, y1)) end
		if n == 2 then return -ksin(y0, y1, 1) end
		return -kcos(y0, y1)
	end

	function M.cos_f64(x)
		local ix = band(hi(x), 0x7fffffff)
		if ix <= 0x3fe921fb then
			if ix < 0x3e46a09e then return 1.0 end
			return (kcos(x, 0.0))
		end
		if ix >= 0x7ff00000 then return x - x end
		local n, y0, y1 = rem_pio2(x)
		n = band(n, 3)
		if n == 0 then return (kcos(y0, y1)) end
		if n == 1 then return -ksin(y0, y1, 1) end
		if n == 2 then return -kcos(y0, y1) end
		return (ksin(y0, y1, 1))
	end

	function M.tan_f64(x)
		local ix = band(hi(x), 0x7fffffff)
		if ix <= 0x3fe921fb then
			if ix < 0x3e400000 then return x end
			return (ktan(x, 0.0, false))
		end
		if ix >= 0x7ff00000 then return x - x end
		local n, y0, y1 = rem_pio2(x)
		return (ktan(y0, y1, band(n, 1) ~= 0))
	end

	-- Zig std asin/acos (asinBinary64, acosBinary64).
	local function rational64(z)
		local p = z * (1.66666666666666657415e-01 + z * (-3.25565818622400915405e-01 + z * (2.01212532134862925881e-01
			+ z * (-4.00555345006794114027e-02 + z * (7.91534994289814532176e-04 + z * 3.47933107596021167570e-05)))))
		local q = 1.0 + z * (-2.40339491173441421878e+00 + z * (2.02094576023350569471e+00 + z * (-6.88283971605453293030e-01
			+ z * 7.70381505559019352791e-02)))
		return p / q
	end
	local PIO2_HI, PIO2_LO = 1.57079632679489655800e+00, 6.12323399573676603587e-17
	local TINY = 2 ^ -120

	function M.asin_f64(x)
		local hx = hi(x)
		local ix = band(hx, 0x7fffffff)
		if ix >= 0x3ff00000 then
			if ix == 0x3ff00000 and lo(x) == 0 then return x * PIO2_HI + TINY end
			return 0.0 / (x - x)
		end
		if ix < 0x3fe00000 then
			if ix < 0x3e500000 and ix >= 0x00100000 then return x end
			return x + x * rational64(x * x)
		end
		local z = (1.0 - abs(x)) * 0.5
		local s = sqrt(z)
		local r = rational64(z)
		local v
		if ix >= 0x3fef3333 then
			v = PIO2_HI - (2 * (s + s * r) - PIO2_LO)
		else
			local f = with_lo(s, 0)
			local c = (z - f * f) / (s + f)
			v = 0.5 * PIO2_HI - (2.0 * s * r - (PIO2_LO - 2.0 * c) - (0.5 * PIO2_HI - 2.0 * f))
		end
		if hx >= 0x80000000 then return -v end
		return v
	end

	function M.acos_f64(x)
		local hx = hi(x)
		local ix = band(hx, 0x7fffffff)
		if ix >= 0x3ff00000 then
			if ix == 0x3ff00000 and lo(x) == 0 then
				if hx >= 0x80000000 then return 2.0 * PIO2_HI + TINY end
				return 0.0
			end
			return 0.0 / (x - x)
		end
		if ix < 0x3fe00000 then
			if ix <= 0x3c600000 then return PIO2_HI + TINY end
			return PIO2_HI - (x - (PIO2_LO - x * rational64(x * x)))
		end
		if hx >= 0x80000000 then
			local z = (1.0 + x) * 0.5
			local s = sqrt(z)
			local w = rational64(z) * s - PIO2_LO
			return 2 * (PIO2_HI - (s + w))
		end
		local z = (1.0 - x) * 0.5
		local s = sqrt(z)
		local df = with_lo(s, 0)
		local c = (z - df * df) / (s + df)
		local w = rational64(z) * s + c
		return 2.0 * (df + w)
	end

	-- Zig std atanBinary64.
	local ATANHI = { [0] = 4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01, 1.57079632679489655800e+00 }
	local ATANLO = { [0] = 2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17, 6.12323399573676603587e-17 }
	local AT = {
		[0] = 3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
		-1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
		6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
		-3.65315727442169155270e-02, 1.62858201153657823623e-02,
	}
	function M.atan_f64(x)
		local h = hi(x)
		local ix = band(h, 0x7fffffff)
		local sign = h >= 0x80000000
		if ix >= 0x44100000 then
			if x ~= x then return x end
			local z = ATANHI[3] + TINY
			return sign and -z or z
		end
		local xr, id = x, nil
		if ix < 0x3fdc0000 then
			if ix < 0x3e400000 then return x end
		else
			local xa = abs(x)
			if ix < 0x3ff30000 then
				if ix < 0x3fe60000 then
					xr, id = (2.0 * xa - 1.0) / (2.0 + xa), 0
				else
					xr, id = (xa - 1.0) / (xa + 1.0), 1
				end
			elseif ix < 0x40038000 then
				xr, id = (xa - 1.5) / (1.0 + 1.5 * xa), 2
			else
				xr, id = -1.0 / xa, 3
			end
		end
		local z = xr * xr
		local w = z * z
		local s1 = z * (AT[0] + w * (AT[2] + w * (AT[4] + w * (AT[6] + w * (AT[8] + w * AT[10])))))
		local s2 = w * (AT[1] + w * (AT[3] + w * (AT[5] + w * (AT[7] + w * AT[9]))))
		if id then
			local zz = ATANHI[id] - (xr * (s1 + s2) - ATANLO[id] - xr)
			return sign and -zz or zz
		end
		return xr - xr * (s1 + s2)
	end

	function M.atan2_f64(y, x)
		local pi, pi_lo = 3.1415926535897931160E+00, 1.2246467991473531772E-16
		if x ~= x or y ~= y then return x + y end
		local xh, xl, yh, yl = hi(x), lo(x), hi(y), lo(y)
		if xh == 0x3FF00000 and xl == 0 then return (M.atan_f64(y)) end
		local m = (yh >= 0x80000000 and 1 or 0) + (xh >= 0x80000000 and 2 or 0)
		xh, yh = band(xh, 0x7FFFFFFF), band(yh, 0x7FFFFFFF)
		if yh == 0 and yl == 0 then
			if m <= 1 then return y end
			if m == 2 then return pi end
			return -pi
		end
		if xh == 0 and xl == 0 then return (m % 2 == 1) and -pi / 2 or pi / 2 end
		if xh == 0x7FF00000 then
			if yh == 0x7FF00000 then
				if m == 0 then return pi / 4 end
				if m == 1 then return -pi / 4 end
				if m == 2 then return 3 * pi / 4 end
				return -3 * pi / 4
			end
			if m == 0 then return 0.0 end
			if m == 1 then return -0.0 end
			if m == 2 then return pi end
			return -pi
		end
		if xh + 0x04000000 < yh or yh == 0x7FF00000 then return (m % 2 == 1) and -pi / 2 or pi / 2 end
		local z
		if m >= 2 and yh + 0x04000000 < xh then
			z = 0.0
		else
			z = M.atan_f64(abs(y / x))
		end
		if m == 0 then return z end
		if m == 1 then return -z end
		if m == 2 then return pi - (z - pi_lo) end
		return (z - pi_lo) - pi
	end

	-- F64 power (f64.zig finitePowerMagnitude, the non-FMA fdlibm path).
	local BP = { [0] = 1.0, 1.5 }
	local DP_HIGH = { [0] = 0.0, 5.84962487220764160156e-01 }
	local DP_LOW = { [0] = 0.0, 1.35003920212974897128e-08 }
	local L1, L2, L3 = 5.99999999999994648725e-01, 4.28571428578550184252e-01, 3.33333329818377432918e-01
	local L4, L5, L6 = 2.72728123808534006489e-01, 2.30660745775561754067e-01, 2.06975017800338417784e-01
	local P1, P2, P3 = 1.66666666666666019037e-01, -2.77777777770155933842e-03, 6.61375632143793436117e-05
	local P4, P5 = -1.65339022054652515390e-06, 4.13813679705723846039e-08
	local LN2, LN2_HIGH, LN2_LOW = 6.93147180559945286227e-01, 6.93147182464599609375e-01, -1.90465429995776804525e-09
	local OVERFLOW_TAIL = 8.0085662595372944372e-017
	local INV_LN2, INV_LN2_HIGH, INV_LN2_LOW = 1.44269504088896338700e+00, 1.44269502162933349609e+00, 1.92596299112661746887e-08
	local CP, CP_HIGH, CP_LOW = 9.61796693925975554329e-01, 9.61796700954437255859e-01, -7.02846165095275826516e-09

	local function scale64(value, power)
		local h, l = hi(value), lo(value)
		local sign = h >= 0x80000000 and 0x80000000 or 0
		local e = band(rshift(h, 20), 0x7ff)
		if e == 0x7ff or (band(h, 0x7fffffff) == 0 and l == 0) then return value end
		if e == 0 then
			local s = value * 2 ^ 54
			h, l = hi(s), lo(s)
			e = band(rshift(h, 20), 0x7ff) - 54
		end
		local ne = e + power
		if ne >= 0x7ff then return (words(sign + 0x7ff00000, 0)) end
		if ne > 0 then return (words(sign + band(h, 0xfffff) + ne * 2 ^ 20, l)) end
		if ne <= -54 then return (words(sign, 0)) end
		return words(sign + band(h, 0xfffff) + (ne + 54) * 2 ^ 20, l) * 2 ^ -54
	end

	local function odd_integer64(v)
		if abs(v) >= 2 ^ 53 or v ~= v then return false end
		if trunc(v) ~= v then return false end
		return v % 2 ~= 0
	end

	local function pow_magnitude64(base, exponent)
		local ab = base
		local bh = hi(ab)
		local eh = hi(exponent)
		local eah = band(eh, 0x7fffffff)
		local eneg = eh >= 0x80000000
		local l2h, l2l
		if eah > 0x41e00000 then
			if eah > 0x43f00000 then
				if bh <= 0x3fefffff then return eneg and INF or 0.0 end
				if bh >= 0x3ff00000 then return eneg and 0.0 or INF end
			end
			if bh < 0x3fefffff then return eneg and INF or 0.0 end
			if bh > 0x3ff00000 then return eneg and 0.0 or INF end
			local d = ab - 1.0
			local c = d * d * (0.5 - d * (0.3333333333333333333333 - d * 0.25))
			local hp = INV_LN2_HIGH * d
			local lp = d * INV_LN2_LOW - c * INV_LN2
			l2h = with_lo(hp + lp, 0)
			l2l = lp - (l2h - hp)
		else
			local be = 0
			if bh < 0x00100000 then
				ab = ab * 2 ^ 53
				be = be - 53
				bh = hi(ab)
			end
			be = be + rshift(bh, 20) - 0x3ff
			local fh = band(bh, 0x000fffff)
			local k
			if fh <= 0x3988e then
				k = 0
			elseif fh < 0xbb67a then
				k = 1
			else
				be = be + 1
				k = 0
			end
			bh = bor(fh, 0x3ff00000)
			if fh >= 0xbb67a then bh = bh - 0x00100000 end
			ab = with_hi(ab, bh)
			local num = ab - BP[k]
			local recip = 1.0 / (ab + BP[k])
			local s = num * recip
			local s_high = with_lo(s, 0)
			local t_high = words(bor(rshift(bh, 1), 0x20000000) + 0x00080000 + k * 2 ^ 18, 0)
			local t_low = ab - (t_high - BP[k])
			local s_low = recip * ((num - s_high * t_high) - s_high * t_low)
			local s2 = s * s
			local rem = s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))))
			rem = rem + s_low * (s_high + s)
			local sh2 = s_high * s_high
			local series_high = with_lo(3.0 + sh2 + rem, 0)
			local series_low = rem - ((series_high - 3.0) - sh2)
			local ph = s_high * series_high
			local pl = s_low * series_high + series_low * s
			local p_high = with_lo(ph + pl, 0)
			local p_low = pl - (p_high - ph)
			local z_high = CP_HIGH * p_high
			local z_low = CP_LOW * p_high + p_low * CP + DP_LOW[k]
			l2h = with_lo((z_high + z_low) + DP_HIGH[k] + be, 0)
			l2l = z_low - (((l2h - be) - DP_HIGH[k]) - z_high)
		end
		local exp_high = with_lo(exponent, 0)
		local product_low = (exponent - exp_high) * l2h + exponent * l2l
		local product_high = exp_high * l2h
		local product = product_high + product_low
		local pwh, pwl = hi(product), lo(product)
		if pwh < 0x80000000 and pwh >= 0x40900000 then
			if pwh ~= 0x40900000 or pwl ~= 0 then return INF end
			if product_low + OVERFLOW_TAIL > product - product_high then return INF end
		elseif pwh >= 0x80000000 and band(pwh, 0x7fffffff) >= 0x4090cc00 then
			if pwh ~= 0xc090cc00 or pwl ~= 0 then return 0.0 end
			if product_low <= product - product_high then return 0.0 end
		end
		local pah = band(pwh, 0x7fffffff)
		local re = rshift(pah, 20) - 0x3ff
		local se = 0
		if pah > 0x3fe00000 then
			local sph = bit.tobit(pwh)
			local rh = bit.tobit(sph + arshift(0x00100000, re + 1))
			local ru = rh % 2 ^ 32
			re = rshift(band(ru, 0x7fffffff), 20) - 0x3ff
			local truncated = band(ru, bnot(rshift(0x000fffff, re))) % 2 ^ 32
			local rounded_value = words(truncated, 0)
			se = rshift(bor(band(ru, 0x000fffff), 0x00100000), 20 - re)
			if sph < 0 then se = -se end
			product_high = product_high - rounded_value
		end
		local residual = with_lo(product_low + product_high, 0)
		local rh = residual * LN2_HIGH
		local rl = (product_low - (residual - product_high)) * LN2 + residual * LN2_LOW
		local ea = rh + rl
		local et = rl - (ea - rh)
		local sq = ea * ea
		local c = ea - sq * (P1 + sq * (P2 + sq * (P3 + sq * (P4 + sq * P5))))
		local approx = (ea * c) / (c - 2.0) - (et + ea * et)
		ea = 1.0 - (approx - ea)
		return (scale64(ea, se))
	end

	function M.pow_f64(base, exponent)
		if exponent == 0.0 or base == 1.0 then return 1.0 end
		if base ~= base or exponent ~= exponent then return NAN end
		if exponent == 1.0 then return base end
		if exponent == -1.0 then return 1.0 / base end
		if exponent == 2.0 then return base * base end
		if base == 0 then
			if exponent < 0.0 then
				if odd_integer64(exponent) then return signbit(base) and -INF or INF end
				return INF
			end
			if odd_integer64(exponent) then return base end
			return 0.0
		end
		if exponent == INF or exponent == -INF then
			if base == -1.0 then return 1.0 end
			if (abs(base) < 1.0) == (exponent > 0.0) then return 0.0 end
			return INF
		end
		if base == INF or base == -INF then
			if base < 0 then return (M.pow_f64(-0.0, -exponent)) end
			return exponent < 0.0 and 0.0 or INF
		end
		if exponent == 0.5 then return (sqrt(base)) end
		if exponent == -0.5 then return 1.0 / sqrt(base) end
		if base < 0.0 and trunc(exponent) ~= exponent then return NAN end
		local r = pow_magnitude64(abs(base), exponent)
		if base < 0.0 and odd_integer64(exponent) then r = -r end
		return r
	end

	-- Zig 0.16 compiler_rt/log.zig (MIT; ported from musl). Roc's @log
	-- links this implementation, independently of the host system libm.
	do
		local P1 = { -0x1p-1, 0x1.5555555555577p-2, -0x1.ffffffffffdcbp-3, 0x1.999999995dd0cp-3, -0x1.55555556745a7p-3, 0x1.24924a344de3p-3, -0x1.fffffa4423d65p-4, 0x1.c7184282ad6cap-4, -0x1.999eb43b068ffp-4, 0x1.78182f7afd085p-4, -0x1.5521375d145cdp-4 }
		local P = { -0x1.0000000000001p-1, 0x1.555555551305bp-2, -0x1.fffffffeb459p-3, 0x1.999b324f10111p-3, -0x1.55575e506c89fp-3 }
		local T = {
			{ 0x1.734f0c3e0de9fp+0, -0x1.7cc7f79e69000p-2, 0x1.61000014fb66bp-1, 0x1.e026c91425b3cp-56 },
			{ 0x1.713786a2ce91fp+0, -0x1.76feec20d0000p-2, 0x1.63000034db495p-1, 0x1.dbfea48005d41p-55 },
			{ 0x1.6f26008fab5a0p+0, -0x1.713e31351e000p-2, 0x1.650000d94d478p-1, 0x1.e7fa786d6a5b7p-55 },
			{ 0x1.6d1a61f138c7dp+0, -0x1.6b85b38287800p-2, 0x1.67000074e6fadp-1, 0x1.1fcea6b54254cp-57 },
			{ 0x1.6b1490bc5b4d1p+0, -0x1.65d5590807800p-2, 0x1.68ffffedf0faep-1, -0x1.c7e274c590efdp-56 },
			{ 0x1.69147332f0cbap+0, -0x1.602d076180000p-2, 0x1.6b0000763c5bcp-1, -0x1.ac16848dcda01p-55 },
			{ 0x1.6719f18224223p+0, -0x1.5a8ca86909000p-2, 0x1.6d0001e5cc1f6p-1, 0x1.33f1c9d499311p-55 },
			{ 0x1.6524f99a51ed9p+0, -0x1.54f4356035000p-2, 0x1.6efffeb05f63ep-1, -0x1.e80041ae22d53p-56 },
			{ 0x1.63356aa8f24c4p+0, -0x1.4f637c36b4000p-2, 0x1.710000e86978p-1, 0x1.bff6671097952p-56 },
			{ 0x1.614b36b9ddc14p+0, -0x1.49da7fda85000p-2, 0x1.72ffffc67e912p-1, 0x1.c00e226bd8724p-55 },
			{ 0x1.5f66452c65c4cp+0, -0x1.445923989a800p-2, 0x1.74fffdf81116ap-1, -0x1.e02916ef101d2p-57 },
			{ 0x1.5d867b5912c4fp+0, -0x1.3edf439b0b800p-2, 0x1.770000f679c9p-1, -0x1.7fc71cd549c74p-57 },
			{ 0x1.5babccb5b90dep+0, -0x1.396ce448f7000p-2, 0x1.78ffffa7ec835p-1, 0x1.1bec19ef50483p-55 },
			{ 0x1.59d61f2d91a78p+0, -0x1.3401e17bda000p-2, 0x1.7affffe20c2e6p-1, -0x1.07e1729cc6465p-56 },
			{ 0x1.5805612465687p+0, -0x1.2e9e2ef468000p-2, 0x1.7cfffed3fc9p-1, -0x1.08072087b8b1cp-55 },
			{ 0x1.56397cee76bd3p+0, -0x1.2941b3830e000p-2, 0x1.7efffe9261a76p-1, 0x1.dc0286d9df9aep-55 },
			{ 0x1.54725e2a77f93p+0, -0x1.23ec58cda8800p-2, 0x1.81000049ca3e8p-1, 0x1.97fd251e54c33p-55 },
			{ 0x1.52aff42064583p+0, -0x1.1e9e129279000p-2, 0x1.8300017932c8fp-1, -0x1.afee9b630f381p-55 },
			{ 0x1.50f22dbb2bddfp+0, -0x1.1956d2b48f800p-2, 0x1.850000633739cp-1, 0x1.9bfbf6b6535bcp-55 },
			{ 0x1.4f38f4734ded7p+0, -0x1.141679ab9f800p-2, 0x1.87000204289c6p-1, -0x1.bbf65f3117b75p-55 },
			{ 0x1.4d843cfde2840p+0, -0x1.0edd094ef9800p-2, 0x1.88fffebf57904p-1, -0x1.9006ea23dcb57p-55 },
			{ 0x1.4bd3ec078a3c8p+0, -0x1.09aa518db1000p-2, 0x1.8b00022bc04dfp-1, -0x1.d00df38e04b0ap-56 },
			{ 0x1.4a27fc3e0258ap+0, -0x1.047e65263b800p-2, 0x1.8cfffe50c1b8ap-1, -0x1.8007146ff9f05p-55 },
			{ 0x1.4880524d48434p+0, -0x1.feb224586f000p-3, 0x1.8effffc918e43p-1, 0x1.3817bd07a7038p-55 },
			{ 0x1.46dce1b192d0bp+0, -0x1.f474a7517b000p-3, 0x1.910001efa5fc7p-1, 0x1.93e9176dfb403p-55 },
			{ 0x1.453d9d3391854p+0, -0x1.ea4443d103000p-3, 0x1.9300013467bb9p-1, 0x1.f804e4b980276p-56 },
			{ 0x1.43a2744b4845ap+0, -0x1.e020d44e9b000p-3, 0x1.94fffe6ee076fp-1, -0x1.f7ef0d9ff622ep-55 },
			{ 0x1.420b54115f8fbp+0, -0x1.d60a22977f000p-3, 0x1.96fffde3c12d1p-1, -0x1.082aa962638bap-56 },
			{ 0x1.40782da3ef4b1p+0, -0x1.cc00104959000p-3, 0x1.98ffff4458a0dp-1, -0x1.7801b9164a8efp-55 },
			{ 0x1.3ee8f5d57fe8fp+0, -0x1.c202956891000p-3, 0x1.9afffdd982e3ep-1, -0x1.740e08a5a9337p-55 },
			{ 0x1.3d5d9a00b4ce9p+0, -0x1.b81178d811000p-3, 0x1.9cfffed49fb66p-1, 0x1.fce08c19bep-60 },
			{ 0x1.3bd60c010c12bp+0, -0x1.ae2c9ccd3d000p-3, 0x1.9f00020f19c51p-1, -0x1.a3faa27885b0ap-55 },
			{ 0x1.3a5242b75dab8p+0, -0x1.a45402e129000p-3, 0x1.a10001145b006p-1, 0x1.4ff489958da56p-56 },
			{ 0x1.38d22cd9fd002p+0, -0x1.9a877681df000p-3, 0x1.a300007bbf6fap-1, 0x1.cbeab8a2b6d18p-55 },
			{ 0x1.3755bc5847a1cp+0, -0x1.90c6d69483000p-3, 0x1.a500010971d79p-1, 0x1.8fecadd78793p-55 },
			{ 0x1.35dce49ad36e2p+0, -0x1.87120a645c000p-3, 0x1.a70001df52e48p-1, -0x1.f41763dd8abdbp-55 },
			{ 0x1.34679984dd440p+0, -0x1.7d68fb4143000p-3, 0x1.a90001c593352p-1, -0x1.ebf0284c27612p-55 },
			{ 0x1.32f5cceffcb24p+0, -0x1.73cb83c627000p-3, 0x1.ab0002a4f3e4bp-1, -0x1.9fd043cff3f5fp-57 },
			{ 0x1.3187775a10d49p+0, -0x1.6a39a9b376000p-3, 0x1.acfffd7ae1ed1p-1, -0x1.23ee7129070b4p-55 },
			{ 0x1.301c8373e3990p+0, -0x1.60b3154b7a000p-3, 0x1.aefffee510478p-1, 0x1.a063ee00edea3p-57 },
			{ 0x1.2eb4ebb95f841p+0, -0x1.5737d76243000p-3, 0x1.b0fffdb650d5bp-1, 0x1.a06c8381f0ab9p-58 },
			{ 0x1.2d50a0219a9d1p+0, -0x1.4dc7b8fc23000p-3, 0x1.b2ffffeaaca57p-1, -0x1.9011e74233c1dp-56 },
			{ 0x1.2bef9a8b7fd2ap+0, -0x1.4462c51d20000p-3, 0x1.b4fffd995badcp-1, -0x1.9ff1068862a9fp-56 },
			{ 0x1.2a91c7a0c1babp+0, -0x1.3b08abc830000p-3, 0x1.b7000249e659cp-1, 0x1.aff45d0864f3ep-55 },
			{ 0x1.293726014b530p+0, -0x1.31b996b490000p-3, 0x1.b8ffff987164p-1, 0x1.cfe7796c2c3f9p-56 },
			{ 0x1.27dfa5757a1f5p+0, -0x1.2875490a44000p-3, 0x1.bafffd204cb4fp-1, -0x1.3ff27eef22bc4p-57 },
			{ 0x1.268b39b1d3bbfp+0, -0x1.1f3b9f879a000p-3, 0x1.bcfffd2415c45p-1, -0x1.cffb7ee3bea21p-57 },
			{ 0x1.2539d838ff5bdp+0, -0x1.160c8252ca000p-3, 0x1.beffff86309dfp-1, -0x1.14103972e0b5cp-55 },
			{ 0x1.23eb7aac9083bp+0, -0x1.0ce7f57f72000p-3, 0x1.c0fffe1b57653p-1, 0x1.bc16494b76a19p-55 },
			{ 0x1.22a012ba940b6p+0, -0x1.03cdc49fea000p-3, 0x1.c2ffff1fa57e3p-1, -0x1.4feef8d30c6edp-57 },
			{ 0x1.2157996cc4132p+0, -0x1.f57bdbc4b8000p-4, 0x1.c4fffdcbfe424p-1, -0x1.43f68bcec4775p-55 },
			{ 0x1.201201dd2fc9bp+0, -0x1.e370896404000p-4, 0x1.c6fffed54b9f7p-1, 0x1.47ea3f053e0ecp-55 },
			{ 0x1.1ecf4494d480bp+0, -0x1.d17983ef94000p-4, 0x1.c8fffeb998fd5p-1, 0x1.383068df992f1p-56 },
			{ 0x1.1d8f5528f6569p+0, -0x1.bf9674ed8a000p-4, 0x1.cb0002125219ap-1, -0x1.8fd8e64180e04p-57 },
			{ 0x1.1c52311577e7cp+0, -0x1.adc79202f6000p-4, 0x1.ccfffdd94469cp-1, 0x1.e7ebe1cc7ea72p-55 },
			{ 0x1.1b17c74cb26e9p+0, -0x1.9c0c3e7288000p-4, 0x1.cefffeafdc476p-1, 0x1.ebe39ad9f88fep-55 },
			{ 0x1.19e010c2c1ab6p+0, -0x1.8a646b372c000p-4, 0x1.d1000169af82bp-1, 0x1.57d91a8b95a71p-56 },
			{ 0x1.18ab07bb670bdp+0, -0x1.78d01b3ac0000p-4, 0x1.d30000d0ff71dp-1, 0x1.9c1906970c7dap-55 },
			{ 0x1.1778a25efbcb6p+0, -0x1.674f145380000p-4, 0x1.d4fffea790fc4p-1, -0x1.80e37c558fe0cp-58 },
			{ 0x1.1648d354c31dap+0, -0x1.55e0e6d878000p-4, 0x1.d70002edc87e5p-1, -0x1.f80d64dc10f44p-56 },
			{ 0x1.151b990275fddp+0, -0x1.4485cdea1e000p-4, 0x1.d900021dc82aap-1, -0x1.47c8f94fd5c5cp-56 },
			{ 0x1.13f0ea432d24cp+0, -0x1.333d94d6aa000p-4, 0x1.dafffd86b0283p-1, 0x1.c7f1dc521617ep-55 },
			{ 0x1.12c8b7210f9dap+0, -0x1.22079f8c56000p-4, 0x1.dd000296c4739p-1, 0x1.8019eb2ffb153p-55 },
			{ 0x1.11a3028ecb531p+0, -0x1.10e4698622000p-4, 0x1.defffe54490f5p-1, 0x1.e00d2c652cc89p-57 },
			{ 0x1.107fbda8434afp+0, -0x1.ffa6c6ad20000p-5, 0x1.e0fffcdabf694p-1, -0x1.f8340202d69d2p-56 },
			{ 0x1.0f5ee0f4e6bb3p+0, -0x1.dda8d4a774000p-5, 0x1.e2fffdb52c8ddp-1, 0x1.b00c1ca1b0864p-56 },
			{ 0x1.0e4065d2a9fcep+0, -0x1.bbcece4850000p-5, 0x1.e4ffff24216efp-1, 0x1.2ffa8b094ab51p-56 },
			{ 0x1.0d244632ca521p+0, -0x1.9a1894012c000p-5, 0x1.e6fffe88a5e11p-1, -0x1.7f673b1efbe59p-58 },
			{ 0x1.0c0a77ce2981ap+0, -0x1.788583302c000p-5, 0x1.e9000119eff0dp-1, -0x1.4808d5e0bc801p-55 },
			{ 0x1.0af2f83c636d1p+0, -0x1.5715e67d68000p-5, 0x1.eafffdfa51744p-1, 0x1.80006d54320b5p-56 },
			{ 0x1.09ddb98a01339p+0, -0x1.35c8a49658000p-5, 0x1.ed0001a127fa1p-1, -0x1.002f860565c92p-58 },
			{ 0x1.08cabaf52e7dfp+0, -0x1.149e364154000p-5, 0x1.ef00007babcc4p-1, -0x1.540445d35e611p-55 },
			{ 0x1.07b9f2f4e28fbp+0, -0x1.e72c082eb8000p-6, 0x1.f0ffff57a8d02p-1, -0x1.ffb3139ef9105p-59 },
			{ 0x1.06ab58c358f19p+0, -0x1.a55f152528000p-6, 0x1.f30001ee58ac7p-1, 0x1.a81acf2731155p-55 },
			{ 0x1.059eea5ecf92cp+0, -0x1.63d62cf818000p-6, 0x1.f4ffff5823494p-1, 0x1.a3f41d4d7c743p-55 },
			{ 0x1.04949cdd12c90p+0, -0x1.228fb8caa0000p-6, 0x1.f6ffffca94c6bp-1, -0x1.202f41c987875p-57 },
			{ 0x1.038c6c6f0ada9p+0, -0x1.c317b20f90000p-7, 0x1.f8fffe1f9c441p-1, 0x1.77dd1f477e74bp-56 },
			{ 0x1.02865137932a9p+0, -0x1.419355daa0000p-7, 0x1.fafffd2e0e37ep-1, -0x1.f01199a7ca331p-57 },
			{ 0x1.0182427ea7348p+0, -0x1.81203c2ec0000p-8, 0x1.fd0001c77e49ep-1, 0x1.181ee4bceacb1p-56 },
			{ 0x1.008040614b195p+0, -0x1.0040979240000p-9, 0x1.feffff7e0c331p-1, -0x1.e05370170875ap-57 },
			{ 0x1.fe01ff726fa1ap-1, 0x1.feff384900000p-9, 0x1.00ffff465606ep+0, -0x1.a7ead491c0adap-55 },
			{ 0x1.fa11cc261ea74p-1, 0x1.7dc41353d0000p-7, 0x1.02ffff3867a58p+0, -0x1.77f69c3fcb2ep-54 },
			{ 0x1.f6310b081992ep-1, 0x1.3cea3c4c28000p-6, 0x1.04ffffdfc0d17p+0, 0x1.7bffe34cb945bp-54 },
			{ 0x1.f25f63ceeadcdp-1, 0x1.b9fc114890000p-6, 0x1.0700003cd4d82p+0, 0x1.20083c0e456cbp-55 },
			{ 0x1.ee9c8039113e7p-1, 0x1.1b0d8ce110000p-5, 0x1.08ffff9f2cbe8p+0, -0x1.dffdfbe37751ap-57 },
			{ 0x1.eae8078cbb1abp-1, 0x1.58a5bd001c000p-5, 0x1.0b000010cda65p+0, -0x1.13f7faee626ebp-54 },
			{ 0x1.e741aa29d0c9bp-1, 0x1.95c8340d88000p-5, 0x1.0d00001a4d338p+0, 0x1.07dfa79489ff7p-55 },
			{ 0x1.e3a91830a99b5p-1, 0x1.d276aef578000p-5, 0x1.0effffadafdfdp+0, -0x1.7040570d66bcp-56 },
			{ 0x1.e01e009609a56p-1, 0x1.07598e598c000p-4, 0x1.110000bbafd96p+0, 0x1.e80d4846d0b62p-55 },
			{ 0x1.dca01e577bb98p-1, 0x1.253f5e30d2000p-4, 0x1.12ffffae5f45dp+0, 0x1.dbffa64fd36efp-54 },
			{ 0x1.d92f20b7c9103p-1, 0x1.42edd8b380000p-4, 0x1.150000dd59ad9p+0, 0x1.a0077701250aep-54 },
			{ 0x1.d5cac66fb5ccep-1, 0x1.606598757c000p-4, 0x1.170000f21559ap+0, 0x1.dfdf9e2e3deeep-55 },
			{ 0x1.d272caa5ede9dp-1, 0x1.7da76356a0000p-4, 0x1.18ffffc275426p+0, 0x1.10030dc3b7273p-54 },
			{ 0x1.cf26e3e6b2ccdp-1, 0x1.9ab434e1c6000p-4, 0x1.1b000123d3c59p+0, 0x1.97f7980030188p-54 },
			{ 0x1.cbe6da2a77902p-1, 0x1.b78c7bb0d6000p-4, 0x1.1cffff8299eb7p+0, -0x1.5f932ab9f8c67p-57 },
			{ 0x1.c8b266d37086dp-1, 0x1.d431332e72000p-4, 0x1.1effff48ad4p+0, 0x1.37fbf9da75bebp-54 },
			{ 0x1.c5894bd5d5804p-1, 0x1.f0a3171de6000p-4, 0x1.210000c8b86a4p+0, 0x1.f806b91fd5b22p-54 },
			{ 0x1.c26b533bb9f8cp-1, 0x1.067152b914000p-3, 0x1.2300003854303p+0, 0x1.3ffc2eb9fbf33p-54 },
			{ 0x1.bf583eeece73fp-1, 0x1.147858292b000p-3, 0x1.24fffffbcf684p+0, 0x1.601e77e2e2e72p-56 },
			{ 0x1.bc4fd75db96c1p-1, 0x1.2266ecdca3000p-3, 0x1.26ffff52921d9p+0, 0x1.ffcbb767f0c61p-56 },
			{ 0x1.b951e0c864a28p-1, 0x1.303d7a6c55000p-3, 0x1.2900014933a3cp+0, -0x1.202ca3c02412bp-56 },
			{ 0x1.b65e2c5ef3e2cp-1, 0x1.3dfc33c331000p-3, 0x1.2b00014556313p+0, -0x1.2808233f21f02p-54 },
			{ 0x1.b374867c9888bp-1, 0x1.4ba366b7a8000p-3, 0x1.2cfffebfe523bp+0, -0x1.8ff7e384fdcf2p-55 },
			{ 0x1.b094b211d304ap-1, 0x1.5933928d1f000p-3, 0x1.2f0000bb8ad96p+0, -0x1.5ff51503041c5p-55 },
			{ 0x1.adbe885f2ef7ep-1, 0x1.66acd2418f000p-3, 0x1.30ffffb7ae2afp+0, -0x1.10071885e289dp-55 },
			{ 0x1.aaf1d31603da2p-1, 0x1.740f8ec669000p-3, 0x1.32ffffeac5f7fp+0, -0x1.1ff5d3fb7b715p-54 },
			{ 0x1.a82e63fd358a7p-1, 0x1.815c0f51af000p-3, 0x1.350000ca66756p+0, 0x1.57f82228b82bdp-54 },
			{ 0x1.a5740ef09738bp-1, 0x1.8e92954f68000p-3, 0x1.3700011fbf721p+0, 0x1.000bac40dd5ccp-55 },
			{ 0x1.a2c2a90ab4b27p-1, 0x1.9bb3602f84000p-3, 0x1.38ffff9592fb9p+0, -0x1.43f9d2db2a751p-54 },
			{ 0x1.a01a01393f2d1p-1, 0x1.a8bed1c2c0000p-3, 0x1.3b00004ddd242p+0, 0x1.57f6b707638e1p-55 },
			{ 0x1.9d79f24db3c1bp-1, 0x1.b5b515c01d000p-3, 0x1.3cffff5b2c957p+0, 0x1.a023a10bf1231p-56 },
			{ 0x1.9ae2505c7b190p-1, 0x1.c2967ccbcc000p-3, 0x1.3efffeab0b418p+0, 0x1.87f6d66b152bp-54 },
			{ 0x1.9852ef297ce2fp-1, 0x1.cf635d5486000p-3, 0x1.410001532aff4p+0, 0x1.7f8375f198524p-57 },
			{ 0x1.95cbaeea44b75p-1, 0x1.dc1bd3446c000p-3, 0x1.4300017478b29p+0, 0x1.301e672dc5143p-55 },
			{ 0x1.934c69de74838p-1, 0x1.e8c01b8cfe000p-3, 0x1.44fffe795b463p+0, 0x1.9ff69b8b2895ap-55 },
			{ 0x1.90d4f2f6752e6p-1, 0x1.f5509c0179000p-3, 0x1.46fffe80475ep+0, -0x1.5c0b19bc2f254p-54 },
			{ 0x1.8e6528effd79dp-1, 0x1.00e6c121fb800p-2, 0x1.48fffef6fc1e7p+0, 0x1.b4009f23a2a72p-54 },
			{ 0x1.8bfce9fcc007cp-1, 0x1.071b80e93d000p-2, 0x1.4afffe5bea704p+0, -0x1.4ffb7bf0d7d45p-54 },
			{ 0x1.899c0dabec30ep-1, 0x1.0d46b9e867000p-2, 0x1.4d000171027dep+0, -0x1.9c06471dc6a3dp-54 },
			{ 0x1.87427aa2317fbp-1, 0x1.13687334bd000p-2, 0x1.4f0000ff03ee2p+0, 0x1.77f890b85531cp-54 },
			{ 0x1.84f00acb39a08p-1, 0x1.1980d67234800p-2, 0x1.5100012dc4bd1p+0, 0x1.004657166a436p-57 },
			{ 0x1.82a49e8653e55p-1, 0x1.1f8ffe0cc8000p-2, 0x1.530001605277ap+0, -0x1.6bfcece233209p-54 },
			{ 0x1.8060195f40260p-1, 0x1.2595fd7636800p-2, 0x1.54fffecdb704cp+0, -0x1.902720505a1d7p-55 },
			{ 0x1.7e22563e0a329p-1, 0x1.2b9300914a800p-2, 0x1.56fffef5f54a9p+0, 0x1.bbfe60ec96412p-54 },
			{ 0x1.7beb377dcb5adp-1, 0x1.3187210436000p-2, 0x1.5900017e61012p+0, 0x1.87ec581afef9p-55 },
			{ 0x1.79baa679725c2p-1, 0x1.377266dec1800p-2, 0x1.5b00003c93e92p+0, -0x1.f41080abf0ccp-54 },
			{ 0x1.77907f2170657p-1, 0x1.3d54ffbaf3000p-2, 0x1.5d0001d4919bcp+0, -0x1.8812afb254729p-54 },
			{ 0x1.756cadbd6130cp-1, 0x1.432eee32fe000p-2, 0x1.5efffe7b87a89p+0, -0x1.47eb780ed6904p-54 },
		}

		function M.log_f64(x)
			if x >= 1 - 0x1p-4 and x < 1 + 0x1.09p-4 then
				if x == 1 then return 0 end
				local r = x - 1
				local r2 = r * r
				local r3 = r * r2
				local y = r3 * (P1[2] + r * P1[3] + r2 * P1[4] +
					r3 * (P1[5] + r * P1[6] + r2 * P1[7] +
						r3 * (P1[8] + r * P1[9] + r2 * P1[10] + r3 * P1[11])))
				local w = r * 0x1p27
				local rhi = r + w - w
				local rlo = r - rhi
				w = rhi * rhi * P1[1]
				local rh = r + w
				local rl = r - rh + w + P1[1] * rlo * (rhi + r)
				return y + rl + rh
			end
			if x == 0 then return -INF end
			if x == INF then return x end
			if x < 0 or x ~= x then return NAN end
			local hx = hi(x)
			if hx < 0x00100000 then
				x = x * 0x1p52
				hx = hi(x) - 52 * 0x00100000
			end
			local tmp = hx - 0x3fe60000
			local i = floor((tmp % 0x00100000) / 0x2000) + 1
			local k = floor(tmp / 0x00100000)
			local z = words(hx - k * 0x00100000, lo(x))
			local t = T[i]
			local r = (z - t[3] - t[4]) * t[1]
			local w = k * 0x1.62e42fefa3800p-1 + t[2]
			local rh = w + r
			local rl = w - rh + r + k * 0x1.ef35793c76730p-45
			local r2 = r * r
			return rl + r2 * P[1] + r * r2 * (P[2] + r * P[3] + r2 * (P[4] + r * P[5])) + rh
		end
	end

	-- F32 (f32.zig) -------------------------------------------------------------

	-- 2/pi as 16-bit limbs (least significant first), from two_over_pi's u64s.
	local TWO_OVER_PI = {}
	do
		local words64 = { "fe5163abdebbc561", "db6295993c439041", "fc2757d1f534ddc0", "a2f9836e4e441529" }
		for _, w in ipairs(words64) do
			for k = 3, 0, -1 do TWO_OVER_PI[#TWO_OVER_PI + 1] = tonumber(w:sub(4 * k + 1, 4 * k + 4), 16) end
		end
	end
	local FIXED_LIMBS = 20 -- 320 bits

	local function fixed_mul(significand)
		local out, carry = {}, 0
		for i = 1, FIXED_LIMBS do
			local x = (TWO_OVER_PI[i] or 0) * significand + carry
			out[i] = x % 65536
			carry = floor(x / 65536)
		end
		return out
	end
	local function fixed_bit(v, i)
		if i >= 320 then return false end
		return floor(v[floor(i / 16) + 1] / 2 ^ (i % 16)) % 2 == 1
	end
	local function lower_bits(v, count)
		local out = {}
		for i = 1, FIXED_LIMBS do
			local base = (i - 1) * 16
			if base + 16 <= count then
				out[i] = v[i]
			elseif base < count then
				out[i] = v[i] % 2 ^ (count - base)
			else
				out[i] = 0
			end
		end
		return out
	end
	local function power_of_two_minus(v, e)
		local out, borrow = {}, 0
		local limb, b = floor(e / 16) + 1, e % 16
		for i = 1, FIXED_LIMBS do
			local x = (i == limb and 2 ^ b or 0) - v[i] - borrow
			if x < 0 then
				out[i] = x + 65536
				borrow = 1
			else
				out[i] = x
				borrow = 0
			end
		end
		return out
	end
	local function highest_set_bit(v)
		for i = FIXED_LIMBS, 1, -1 do
			local x = v[i]
			if x ~= 0 then
				local b = 0
				while x >= 2 do
					x = floor(x / 2)
					b = b + 1
				end
				return (i - 1) * 16 + b
			end
		end
		return nil
	end
	local function shifted_low_u32(v, shift)
		local r = 0
		for k = 31, 0, -1 do r = r * 2 + (fixed_bit(v, shift + k) and 1 or 0) end
		return r
	end
	local function any_bits_below(v, count)
		for i = 0, math.min(count, 320) - 1 do
			if fixed_bit(v, i) then return true end
		end
		return false
	end
	local function rounded_shift(v, shift)
		if shift <= 0 then return (shifted_low_u32(v, 0) * 2 ^ (-shift)) % 2 ^ 32 end
		local r = shifted_low_u32(v, shift)
		if fixed_bit(v, shift - 1) and (any_bits_below(v, shift - 1) or r % 2 == 1) then r = r + 1 end
		return r
	end
	local function fixed_fraction_to_f32(mag, den)
		local highest = highest_set_bit(mag)
		if highest == nil then return 0.0 end
		local ue = highest - den
		if ue >= -126 then
			local sig = rounded_shift(mag, highest - 23)
			if sig == 0x01000000 then
				sig = sig / 2
				ue = ue + 1
			end
			return (f32_of((ue + 127) * 2 ^ 23 + sig % 2 ^ 23))
		end
		return (f32_of(rounded_shift(mag, den - 149)))
	end

	local P32_HI, P32_LO = R(1.5707962513e+00), R(7.5497894159e-08)

	-- Exact reduction modulo pi/2 by fixed-point 2/pi: quadrant, remainder.
	local function reduce32(value)
		local bits = b32(value)
		local ab = bits % 2 ^ 31
		local eb = floor(ab / 2 ^ 23) % 256
		local significand = ab % 2 ^ 23 + 2 ^ 23
		local den = 256 - (eb - 150)
		local product = fixed_mul(significand)
		local rounds_up = fixed_bit(product, den - 1)
		local quadrant = (fixed_bit(product, den) and 1 or 0) + (fixed_bit(product, den + 1) and 2 or 0)
		if rounds_up then quadrant = (quadrant + 1) % 4 end
		local fraction = lower_bits(product, den)
		local magnitude = rounds_up and power_of_two_minus(fraction, den) or fraction
		local rf = fixed_fraction_to_f32(magnitude, den)
		local negative = bits >= 2 ^ 31
		if rounds_up ~= negative then rf = -rf end
		if negative then quadrant = (4 - quadrant) % 4 end
		return quadrant, R(R(rf * P32_HI) + R(rf * P32_LO))
	end

	local S32 = { R(-1.6666667163e-01), R(8.3333291113e-03), R(-1.9839334413e-04), R(2.7183114939e-06) }
	local C32 = { R(-4.9999997020e-01), R(4.1666623205e-02), R(-1.3886763481e-03), R(2.4390447366e-05) }
	local function ksin32(x)
		if b32(x) % 2 ^ 31 < 0x39800000 then return x end
		local z = R(x * x)
		local poly = R(S32[1] + R(z * R(S32[2] + R(z * R(S32[3] + R(z * S32[4]))))))
		return (R(x + R(R(x * z) * poly)))
	end
	local function kcos32(x)
		local z = R(x * x)
		local w = R(z * z)
		return (R(R(R(1.0 + R(z * C32[1])) + R(w * C32[2])) + R(R(w * z) * R(C32[3] + R(z * C32[4])))))
	end
	local function sin_cos32(value)
		local ab = b32(value) % 2 ^ 31
		if ab >= 0x7f800000 then
			local nan = value - value
			return nan, nan
		end
		local quadrant, rem
		if ab <= 0x3f490fda then
			quadrant, rem = 0, value
		else
			quadrant, rem = reduce32(value)
		end
		local s, c = ksin32(rem), kcos32(rem)
		if quadrant == 0 then return s, c end
		if quadrant == 1 then return c, -s end
		if quadrant == 2 then return -s, -c end
		return -c, s
	end
	function M.sin_f32(x) return (sin_cos32(x)) end
	function M.cos_f32(x)
		local _, c = sin_cos32(x)
		return c
	end
	function M.tan_f32(x)
		local s, c = sin_cos32(x)
		return (R(s / c))
	end

	local IR = { R(1.6666586697e-01), R(-4.2743422091e-02), R(-8.6563630030e-03), R(-7.0662963390e-01) }
	local function inverse_rational(z)
		local numerator = R(z * R(IR[1] + R(z * R(IR[2] + R(z * IR[3])))))
		local denominator = R(1.0 + R(z * IR[4]))
		return (R(numerator / denominator))
	end

	function M.asin_f32(value)
		local bits = b32(value)
		local ab = bits % 2 ^ 31
		if ab >= 0x3f800000 then
			if ab == 0x3f800000 then
				local r = R(P32_HI + P32_LO)
				return bits < 2 ^ 31 and r or -r
			end
			return NAN
		end
		if ab < 0x3f000000 then
			if ab < 0x39800000 then return value end
			return (R(value + R(value * inverse_rational(R(value * value)))))
		end
		local z = R(R(1.0 - abs(value)) * 0.5)
		local root = R(sqrt(z))
		local ratio = inverse_rational(z)
		local v = R(P32_HI - R(R(2.0 * R(root + R(root * ratio))) - P32_LO))
		return bits < 2 ^ 31 and v or -v
	end

	function M.acos_f32(value)
		local bits = b32(value)
		local ab = bits % 2 ^ 31
		if ab >= 0x3f800000 then
			if ab == 0x3f800000 then
				if bits < 2 ^ 31 then return 0.0 end
				return (R(2.0 * R(P32_HI + P32_LO)))
			end
			return NAN
		end
		if ab < 0x3f000000 then
			if ab <= 0x32800000 then return (R(P32_HI + P32_LO)) end
			return (R(P32_HI - R(value - R(P32_LO - R(value * inverse_rational(R(value * value)))))))
		end
		if bits >= 2 ^ 31 then
			local z = R(R(1.0 + value) * 0.5)
			local root = R(sqrt(z))
			local correction = R(R(inverse_rational(z) * root) - P32_LO)
			return (R(2.0 * R(P32_HI - R(root + correction))))
		end
		local z = R(R(1.0 - value) * 0.5)
		local root = R(sqrt(z))
		local root_hi = f32_of(band(b32(root), 0xfffff000) % 2 ^ 32)
		local correction = R(R(z - R(root_hi * root_hi)) / R(root + root_hi))
		local tail = R(R(inverse_rational(z) * root) + correction)
		return (R(2.0 * R(root_hi + tail)))
	end

	local A32_HIGH = { [0] = R(4.6364760399e-01), R(7.8539812565e-01), R(9.8279368877e-01), R(1.5707962513e+00) }
	local A32_LOW = { [0] = R(5.0121582440e-09), R(3.7748947079e-08), R(3.4473217170e-08), R(7.5497894159e-08) }
	local A32 = { [0] = R(3.3333328366e-01), R(-1.9999158382e-01), R(1.4253635705e-01), R(-1.0648017377e-01), R(6.1687607318e-02) }
	function M.atan_f32(value)
		local bits = b32(value)
		local ab = bits % 2 ^ 31
		local negative = bits >= 2 ^ 31
		if ab >= 0x4c800000 then
			if ab > 0x7f800000 then return value end
			local r = R(A32_HIGH[3] + A32_LOW[3])
			return negative and -r or r
		end
		local reduced, id = value, nil
		if ab < 0x3ee00000 then
			if ab < 0x39800000 then return value end
		else
			local m = abs(value)
			if ab < 0x3f980000 then
				if ab < 0x3f300000 then
					reduced, id = R(R(R(2.0 * m) - 1.0) / R(2.0 + m)), 0
				else
					reduced, id = R(R(m - 1.0) / R(m + 1.0)), 1
				end
			elseif ab < 0x401c0000 then
				reduced, id = R(R(m - 1.5) / R(1.0 + R(1.5 * m))), 2
			else
				reduced, id = R(-1.0 / m), 3
			end
		end
		local z = R(reduced * reduced)
		local w = R(z * z)
		local odd = R(z * R(A32[0] + R(w * R(A32[2] + R(w * A32[4])))))
		local even = R(w * R(A32[1] + R(w * A32[3])))
		if id then
			local r = R(A32_HIGH[id] - R(R(R(reduced * R(odd + even)) - A32_LOW[id]) - reduced))
			return negative and -r or r
		end
		return (R(reduced - R(reduced * R(odd + even))))
	end

	function M.atan2_f32(y, x)
		local pi, pi_lo = R(3.1415927410e+00), R(-8.7422776573e-08)
		if x ~= x or y ~= y then return (R(x + y)) end
		local xb, yb = b32(x), b32(y)
		if xb == 0x3F800000 then return (M.atan_f32(y)) end
		local m = (yb >= 2 ^ 31 and 1 or 0) + (xb >= 2 ^ 31 and 2 or 0)
		xb, yb = xb % 2 ^ 31, yb % 2 ^ 31
		if yb == 0 then
			if m <= 1 then return y end
			if m == 2 then return pi end
			return -pi
		end
		if xb == 0 then return (m % 2 == 1) and -pi / 2 or pi / 2 end
		if xb == 0x7F800000 then
			if yb == 0x7F800000 then
				if m == 0 then return pi / 4 end
				if m == 1 then return -pi / 4 end
				if m == 2 then return (R(R(3 * pi) / 4)) end
				return (R(R(-3 * pi) / 4))
			end
			if m == 0 then return 0.0 end
			if m == 1 then return -0.0 end
			if m == 2 then return pi end
			return -pi
		end
		if xb + 26 * 2 ^ 23 < yb or yb == 0x7F800000 then return (m % 2 == 1) and -pi / 2 or pi / 2 end
		local z
		if m >= 2 and yb + 26 * 2 ^ 23 < xb then
			z = 0.0
		else
			z = M.atan_f32(abs(R(y / x)))
		end
		if m == 0 then return z end
		if m == 1 then return -z end
		if m == 2 then return (R(pi - R(z - pi_lo))) end
		return (R(R(z - pi_lo) - pi))
	end

	-- F32 natural log (f32.zig log).
	local LN2_HI32, LN2_LO32 = R(6.9313812256e-01), R(9.0580006145e-06)
	local LG1, LG2, LG3, LG4 = 0xaaaaaa / 2 ^ 24, 0xccce13 / 2 ^ 25, 0x91e9ee / 2 ^ 25, 0xf89e26 / 2 ^ 26
	function M.log_f32(value)
		local x = value
		local bits = b32(x)
		local exponent = 0
		if bits < 0x00800000 or bits >= 2 ^ 31 then
			if bits % 2 ^ 31 == 0 then return -INF end
			if bits >= 2 ^ 31 then return NAN end
			exponent = exponent - 25
			x = R(x * 2 ^ 25)
			bits = b32(x)
		elseif bits >= 0x7f800000 then
			return x
		elseif bits == 0x3f800000 then
			return 0.0
		end
		bits = bits + (0x3f800000 - 0x3f3504f3)
		exponent = exponent + floor(bits / 2 ^ 23) - 0x7f
		bits = bits % 2 ^ 23 + 0x3f3504f3
		x = f32_of(bits)
		local f = R(x - 1.0)
		local s = R(f / R(2.0 + f))
		local z = R(s * s)
		local w = R(z * z)
		local approx = R(R(z * R(LG1 + R(w * LG3))) + R(w * R(LG2 + R(w * LG4))))
		local half_square = R(R(0.5 * f) * f)
		local fe = exponent
		return (R(R(R(R(R(s * R(half_square + approx)) + R(fe * LN2_LO32)) - half_square) + f) + R(fe * LN2_HI32)))
	end

	-- F32 power (f32.zig finitePowerMagnitude).
	local PBP = { [0] = 1.0, 1.5 }
	local PDP_HIGH = { [0] = 0.0, R(5.84960938e-01) }
	local PDP_LOW = { [0] = 0.0, R(1.56322085e-06) }
	local PL = { R(6.0000002384e-01), R(4.2857143283e-01), R(3.3333334327e-01), R(2.7272811532e-01), R(2.3066075146e-01), R(2.0697501302e-01) }
	local PP = { R(1.6666667163e-01), R(-2.7777778450e-03), R(6.6137559770e-05), R(-1.6533901999e-06), R(4.1381369442e-08) }
	local PLN2, PLN2_HIGH, PLN2_LOW = R(6.9314718246e-01), R(6.93145752e-01), R(1.42860654e-06)
	local POVERFLOW_TAIL = R(4.2995665694e-08)
	local PCP, PCP_HIGH, PCP_LOW = R(9.6179670095e-01), R(9.6191406250e-01), R(-1.1736857402e-04)
	local PINV_LN2, PINV_LN2_HIGH, PINV_LN2_LOW = R(1.4426950216e+00), R(1.4426879883e+00), R(7.0526075433e-06)
	local THIRD32 = R(0.333333333333)

	local function trunc_high32(v) return (f32_of(band(b32(v), 0xfffff000) % 2 ^ 32)) end

	local function scale32(value, power)
		local bits = b32(value)
		local sign = bits >= 2 ^ 31 and 2 ^ 31 or 0
		local e = floor(bits / 2 ^ 23) % 256
		if e == 0xff or bits % 2 ^ 31 == 0 then return value end
		if e == 0 then
			bits = b32(R(value * 2 ^ 24))
			e = floor(bits / 2 ^ 23) % 256 - 24
		end
		local ne = e + power
		if ne >= 0xff then return (f32_of(sign + 0x7f800000)) end
		if ne > 0 then return (f32_of(sign + bits % 2 ^ 23 + ne * 2 ^ 23)) end
		if ne <= -24 then return (f32_of(sign)) end
		return (R(f32_of(sign + bits % 2 ^ 23 + (ne + 24) * 2 ^ 23) * 2 ^ -24))
	end

	local function odd_integer32(v)
		if abs(v) >= 2 ^ 24 or v ~= v then return false end
		if trunc(v) ~= v then return false end
		return v % 2 ~= 0
	end

	local function pow_magnitude32(base, exponent)
		local ab = base
		local bb = b32(ab)
		local ebits = b32(exponent)
		local eab = ebits % 2 ^ 31
		local eneg = ebits >= 2 ^ 31
		local l2h, l2l
		if eab > 0x4d000000 then
			if bb < 0x3f7ffff8 then return eneg and INF or 0.0 end
			if bb > 0x3f800007 then return eneg and 0.0 or INF end
			local d = R(ab - 1.0)
			local c = R(R(d * d) * R(0.5 - R(d * R(THIRD32 - R(d * 0.25)))))
			local hp = R(PINV_LN2_HIGH * d)
			local lp = R(R(d * PINV_LN2_LOW) - R(c * PINV_LN2))
			l2h = trunc_high32(R(hp + lp))
			l2l = R(lp - R(l2h - hp))
		else
			local be = 0
			if bb < 0x00800000 then
				ab = R(ab * 16777216.0)
				be = be - 24
				bb = b32(ab)
			end
			be = be + floor(bb / 2 ^ 23) - 0x7f
			local fr = bb % 2 ^ 23
			local k
			if fr <= 0x1cc471 then
				k = 0
			elseif fr < 0x5db3d7 then
				k = 1
			else
				be = be + 1
				k = 0
			end
			bb = fr + 0x3f800000
			if fr >= 0x5db3d7 then bb = bb - 0x00800000 end
			ab = f32_of(bb)
			local num = R(ab - PBP[k])
			local recip = R(1.0 / R(ab + PBP[k]))
			local s = R(num * recip)
			local s_high = trunc_high32(s)
			local t_high = f32_of(bor(band(rshift(bb, 1), 0xfffff000), 0x20000000) + 0x00400000 + k * 2 ^ 21)
			local t_low = R(ab - R(t_high - PBP[k]))
			local s_low = R(recip * R(R(num - R(s_high * t_high)) - R(s_high * t_low)))
			local s2 = R(s * s)
			local rem = R(R(s2 * s2) * R(PL[1] + R(s2 * R(PL[2] + R(s2 * R(PL[3] + R(s2 * R(PL[4] + R(s2 * R(PL[5] + R(s2 * PL[6])))))))))))
			rem = R(rem + R(s_low * R(s_high + s)))
			local sh2 = R(s_high * s_high)
			local series_high = trunc_high32(R(R(3.0 + sh2) + rem))
			local series_low = R(rem - R(R(series_high - 3.0) - sh2))
			local ph = R(s_high * series_high)
			local pl = R(R(s_low * series_high) + R(series_low * s))
			local p_high = trunc_high32(R(ph + pl))
			local p_low = R(pl - R(p_high - ph))
			local z_high = R(PCP_HIGH * p_high)
			local z_low = R(R(R(PCP_LOW * p_high) + R(p_low * PCP)) + PDP_LOW[k])
			l2h = trunc_high32(R(R(R(z_high + z_low) + PDP_HIGH[k]) + be))
			l2l = R(z_low - R(R(R(l2h - be) - PDP_HIGH[k]) - z_high))
		end
		local exp_high = trunc_high32(exponent)
		local product_low = R(R(R(exponent - exp_high) * l2h) + R(exponent * l2l))
		local product_high = R(exp_high * l2h)
		local product = R(product_high + product_low)
		local pb = b32(product)
		if pb < 2 ^ 31 and pb >= 0x43000000 then
			if pb ~= 0x43000000 then return INF end
			if R(product_low + POVERFLOW_TAIL) > R(product - product_high) then return INF end
		elseif pb >= 2 ^ 31 and pb % 2 ^ 31 >= 0x43160000 then
			if pb ~= 0xc3160000 then return 0.0 end
			if product_low <= R(product - product_high) then return 0.0 end
		end
		local pab = pb % 2 ^ 31
		local re = floor(pab / 2 ^ 23) - 0x7f
		local se = 0
		if pab > 0x3f000000 then
			local spb = bit.tobit(pb)
			local rb = bit.tobit(spb + arshift(0x00800000, re + 1))
			local ru = rb % 2 ^ 32
			re = floor((ru % 2 ^ 31) / 2 ^ 23) - 0x7f
			local truncated = band(ru, bnot(rshift(0x007fffff, re))) % 2 ^ 32
			local rounded_value = f32_of(truncated)
			se = rshift(bor(band(ru, 0x007fffff), 0x00800000), 23 - re)
			if spb < 0 then se = -se end
			product_high = R(product_high - rounded_value)
		end
		local residual = f32_of(band(b32(R(product_low + product_high)), 0xffff8000) % 2 ^ 32)
		local rh = R(residual * PLN2_HIGH)
		local rl = R(R(R(product_low - R(residual - product_high)) * PLN2) + R(residual * PLN2_LOW))
		local ea = R(rh + rl)
		local et = R(rl - R(ea - rh))
		local sq = R(ea * ea)
		local c = R(ea - R(sq * R(PP[1] + R(sq * R(PP[2] + R(sq * R(PP[3] + R(sq * R(PP[4] + R(sq * PP[5]))))))))))
		local approx = R(R(R(ea * c) / R(c - 2.0)) - R(et + R(ea * et)))
		ea = R(1.0 - R(approx - ea))
		return (scale32(ea, se))
	end

	function M.pow_f32(base, exponent)
		if exponent == 0.0 or base == 1.0 then return 1.0 end
		if base ~= base or exponent ~= exponent then return NAN end
		if exponent == 1.0 then return base end
		if exponent == -1.0 then return (R(1.0 / base)) end
		if exponent == 2.0 then return (R(base * base)) end
		if base == 0 then
			if exponent < 0.0 then
				if odd_integer32(exponent) then return signbit(base) and -INF or INF end
				return INF
			end
			if odd_integer32(exponent) then return base end
			return 0.0
		end
		if exponent == INF or exponent == -INF then
			if base == -1.0 then return 1.0 end
			if (abs(base) < 1.0) == (exponent > 0.0) then return 0.0 end
			return INF
		end
		if base == INF or base == -INF then
			if base < 0 then return (M.pow_f32(-0.0, -exponent)) end
			return exponent < 0.0 and 0.0 or INF
		end
		if exponent == 0.5 then return (R(sqrt(base))) end
		if exponent == -0.5 then return (R(1.0 / R(sqrt(base)))) end
		if base < 0.0 and trunc(exponent) ~= exponent then return NAN end
		local r = pow_magnitude32(abs(base), exponent)
		if base < 0.0 and odd_integer32(exponent) then r = -r end
		return r
	end

	return M
end

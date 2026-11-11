--[[
	Solver — cards, exact-rational evaluation and the full solution finder.
	A straight port of the web version's section 1. Shared by client and
	server: the server uses it to deal hands and to verify every claim.

	Operators are carried internally as ASCII codes ("+", "-", "*", "/") and
	only turned into − × ÷ glyphs for display. Card indices are 1-based.
]]

local Solver = {}

export type Card = { v: number, s: number } -- v: 1..13, s: suit 1..4
export type Rat = { n: number, d: number }
export type Tree = { type: string, v: number?, cardIdx: number?, op: string?, l: Tree?, r: Tree? }
export type Tok = { type: string, cardIdx: number?, op: string? }

Solver.OPS = { "+", "-", "*", "/" }
Solver.GLYPH = { ["+"] = "+", ["-"] = "\u{2212}", ["*"] = "\u{00D7}", ["/"] = "\u{00F7}" }
-- suit order matches the web version: spade, heart, diamond, club
Solver.SUIT_NAMES = { "spade", "heart", "diamond", "club" }
Solver.SUIT_RED = { false, true, true, false }

local EPS = 1e-6

function Solver.rankLabel(v: number): string
	if v == 1 then
		return "A"
	elseif v == 11 then
		return "J"
	elseif v == 12 then
		return "Q"
	elseif v == 13 then
		return "K"
	end
	return tostring(v)
end

local function canMake24(nums: { number }): boolean
	local n = #nums
	if n == 1 then
		return math.abs(nums[1] - 24) < EPS
	end
	for i = 1, n do
		for j = 1, n do
			if i ~= j then
				local rest = {}
				for k = 1, n do
					if k ~= i and k ~= j then
						table.insert(rest, nums[k])
					end
				end
				local a, b = nums[i], nums[j]
				local cands = { a + b, a - b, a * b }
				if math.abs(b) > 1e-9 then
					table.insert(cands, a / b)
				end
				for _, c in cands do
					table.insert(rest, c)
					if canMake24(rest) then
						return true
					end
					table.remove(rest)
				end
			end
		end
	end
	return false
end
Solver.canMake24 = canMake24

local rng = Random.new()

function Solver.generatePuzzle(): { Card }
	local vals
	local guard = 0
	repeat
		vals = {}
		for i = 1, 4 do
			vals[i] = rng:NextInteger(1, 13)
		end
		guard += 1
	until canMake24(vals) or guard >= 800
	local out = {}
	for i = 1, 4 do
		out[i] = { v = vals[i], s = rng:NextInteger(1, 4) }
	end
	return out
end

---------------------------------------------------------------------------
-- exact rationals
---------------------------------------------------------------------------
local function gcd(a: number, b: number): number
	a, b = math.abs(a), math.abs(b)
	while b ~= 0 do
		a, b = b, a % b
	end
	return if a == 0 then 1 else a
end

local function rat(n: number, d: number): Rat?
	if d == 0 then
		return nil
	end
	if d < 0 then
		n, d = -n, -d
	end
	local g = gcd(n, d)
	n, d = n / g, d / g
	if n == 0 then
		n = 0 -- normalise -0
	end
	return { n = n, d = d }
end
Solver.rat = rat

local function rAdd(a: Rat, b: Rat) return rat(a.n * b.d + b.n * a.d, a.d * b.d) end
local function rSub(a: Rat, b: Rat) return rat(a.n * b.d - b.n * a.d, a.d * b.d) end
local function rMul(a: Rat, b: Rat) return rat(a.n * b.n, a.d * b.d) end
local function rDiv(a: Rat, b: Rat)
	if b.n == 0 then
		return nil
	end
	return rat(a.n * b.d, a.d * b.n)
end

local function applyOp(op: string, a: Rat, b: Rat): Rat?
	if op == "+" then
		return rAdd(a, b)
	elseif op == "-" then
		return rSub(a, b)
	elseif op == "*" then
		return rMul(a, b)
	end
	return rDiv(a, b)
end

function Solver.ratText(r: Rat?): string
	if not r then
		return "\u{2014}"
	end
	if r.d == 1 then
		return string.format("%d", r.n)
	end
	local v = math.round((r.n / r.d) * 100) / 100
	-- mimic JS number printing: no trailing zeros
	local s = string.format("%.2f", v)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	if s == "-0" then
		s = "0"
	end
	return s
end

function Solver.is24(r: Rat?): boolean
	return r ~= nil and r.d == 1 and r.n == 24
end

---------------------------------------------------------------------------
-- evaluator over display tokens: {type="card",cardIdx} | {type="op",op} | {type="("} | {type=")"}
---------------------------------------------------------------------------
function Solver.evaluate(toks: { Tok }, cards: { Card }): Rat?
	local pos = 1
	local parseExpr

	local function peek()
		return toks[pos]
	end

	local function parseFactor(): Rat?
		local tk = peek()
		if not tk then
			return nil
		end
		if tk.type == "card" then
			pos += 1
			local c = cards[tk.cardIdx :: number]
			if not c then
				return nil
			end
			return rat(c.v, 1)
		end
		if tk.type == "(" then
			pos += 1
			local inner = parseExpr()
			if inner == nil then
				return nil
			end
			local close = peek()
			if not close or close.type ~= ")" then
				return nil
			end
			pos += 1
			return inner
		end
		return nil
	end

	local function parseTerm(): Rat?
		local left = parseFactor()
		if left == nil then
			return nil
		end
		while peek() and peek().type == "op" and (peek().op == "*" or peek().op == "/") do
			local op = toks[pos].op :: string
			pos += 1
			local right = parseFactor()
			if right == nil then
				return nil
			end
			left = applyOp(op, left :: Rat, right)
			if left == nil then
				return nil
			end
		end
		return left
	end

	parseExpr = function(): Rat?
		local left = parseTerm()
		if left == nil then
			return nil
		end
		while peek() and peek().type == "op" and (peek().op == "+" or peek().op == "-") do
			local op = toks[pos].op :: string
			pos += 1
			local right = parseTerm()
			if right == nil then
				return nil
			end
			left = applyOp(op, left :: Rat, right)
			if left == nil then
				return nil
			end
		end
		return left
	end

	local res = parseExpr()
	if res == nil or pos ~= #toks + 1 then
		return nil
	end
	return res
end

---------------------------------------------------------------------------
-- solution finder: every expression tree that reaches 24
---------------------------------------------------------------------------
local function opPrec(op: string): number
	return if (op == "+" or op == "-") then 1 else 2
end

function Solver.solveAllTrees(cards: { Card }): { Tree }
	local out = {}
	local leaves = {}
	for idx, c in cards do
		table.insert(leaves, { val = rat(c.v, 1), tree = { type = "leaf", v = c.v, cardIdx = idx } })
	end
	local function recurse(nodes)
		local n = #nodes
		if n == 1 then
			local v = nodes[1].val
			if v and v.d == 1 and v.n == 24 then
				table.insert(out, nodes[1].tree)
			end
			return
		end
		for i = 1, n do
			for j = 1, n do
				if i ~= j then
					local rest = {}
					for k = 1, n do
						if k ~= i and k ~= j then
							table.insert(rest, nodes[k])
						end
					end
					local a, b = nodes[i], nodes[j]
					for _, op in Solver.OPS do
						local nv = applyOp(op, a.val, b.val)
						if nv ~= nil then
							table.insert(rest, { val = nv, tree = { type = "op", op = op, l = a.tree, r = b.tree } })
							recurse(rest)
							table.remove(rest)
						end
					end
				end
			end
		end
	end
	recurse(leaves)
	return out
end

-- Canonical form: chains of the same family (+/− or ×/÷) are flattened into
-- a signed/reciprocal multiset and sorted, so rearrangements of the same
-- terms compare equal. Distribution is deliberately not unified.
local canonAdd

local function collectAdditive(tree: Tree, sign: number, out)
	if tree.type == "op" and (tree.op == "+" or tree.op == "-") then
		collectAdditive(tree.l :: Tree, sign, out)
		collectAdditive(tree.r :: Tree, if tree.op == "+" then sign else -sign, out)
	else
		table.insert(out, { sign = sign, tree = tree })
	end
end

local function collectMultiplicative(tree: Tree, recip: boolean, out)
	if tree.type == "op" and (tree.op == "*" or tree.op == "/") then
		collectMultiplicative(tree.l :: Tree, recip, out)
		collectMultiplicative(tree.r :: Tree, if tree.op == "*" then recip else not recip, out)
	else
		table.insert(out, { recip = recip, tree = tree })
	end
end

local function canonFactor(tree: Tree): string
	if tree.type == "leaf" then
		return "n" .. tostring(tree.v)
	end
	return "(" .. canonAdd(tree) .. ")"
end

local function canonMul(tree: Tree): string
	local factors = {}
	collectMultiplicative(tree, false, factors)
	local parts = {}
	for _, f in factors do
		table.insert(parts, (if f.recip then "/" else "*") .. canonFactor(f.tree))
	end
	table.sort(parts)
	return "M[" .. table.concat(parts, ",") .. "]"
end

local function canonTerm(tree: Tree): string
	if tree.type == "op" and (tree.op == "*" or tree.op == "/") then
		return canonMul(tree)
	end
	return canonFactor(tree)
end

canonAdd = function(tree: Tree): string
	local terms = {}
	collectAdditive(tree, 1, terms)
	local parts = {}
	for _, t in terms do
		table.insert(parts, (if t.sign < 0 then "-" else "+") .. canonTerm(t.tree))
	end
	table.sort(parts)
	return "S[" .. table.concat(parts, ",") .. "]"
end

function Solver.canonTree(tree: Tree): string
	if tree.type == "leaf" then
		return "n" .. tostring(tree.v)
	end
	if tree.op == "+" or tree.op == "-" then
		return canonAdd(tree)
	end
	return canonMul(tree)
end

function Solver.uniqueSolutions(cards: { Card }): { Tree }
	local seen = {}
	local uniq = {}
	for _, t in Solver.solveAllTrees(cards) do
		local c = Solver.canonTree(t)
		if not seen[c] then
			seen[c] = true
			table.insert(uniq, t)
		end
	end
	return uniq
end

-- Renders a solution tree to a flat token stream with minimal parentheses.
function Solver.treeToTokens(tree: Tree): { Tok }
	local function concat(...)
		local out = {}
		for _, list in { ... } do
			for _, t in list do
				table.insert(out, t)
			end
		end
		return out
	end
	local function go(node: Tree): ({ Tok }, number)
		if node.type == "leaf" then
			return { { type = "card", cardIdx = node.cardIdx } }, 99
		end
		local op = node.op :: string
		local myPrec = opPrec(op)
		local lt, lp = go(node.l :: Tree)
		local rt, rp = go(node.r :: Tree)
		if lp < myPrec then
			lt = concat({ { type = "(" } }, lt, { { type = ")" } })
		end
		local nonAssoc = (op == "-" or op == "/")
		if rp < myPrec or (nonAssoc and rp == myPrec) then
			rt = concat({ { type = "(" } }, rt, { { type = ")" } })
		end
		return concat(lt, { { type = "op", op = op } }, rt), myPrec
	end
	local toks = go(tree)
	return toks
end

-- Rebuilds an expression tree from display tokens (for canonical comparison).
function Solver.tokensToTree(toks: { Tok }, cards: { Card }): Tree?
	local pos = 1
	local expr
	local function peek()
		return toks[pos]
	end
	local function factor(): Tree?
		local t = peek()
		if not t then
			return nil
		end
		if t.type == "card" then
			pos += 1
			local c = cards[t.cardIdx :: number]
			if not c then
				return nil
			end
			return { type = "leaf", v = c.v, cardIdx = t.cardIdx }
		end
		if t.type == "(" then
			pos += 1
			local inner = expr()
			local close = peek()
			if not inner or not close or close.type ~= ")" then
				return nil
			end
			pos += 1
			return inner
		end
		return nil
	end
	local function term(): Tree?
		local l = factor()
		if not l then
			return nil
		end
		while peek() and peek().type == "op" and (peek().op == "*" or peek().op == "/") do
			local op = toks[pos].op
			pos += 1
			local r = factor()
			if not r then
				return nil
			end
			l = { type = "op", op = op, l = l, r = r }
		end
		return l
	end
	expr = function(): Tree?
		local l = term()
		if not l then
			return nil
		end
		while peek() and peek().type == "op" and (peek().op == "+" or peek().op == "-") do
			local op = toks[pos].op
			pos += 1
			local r = term()
			if not r then
				return nil
			end
			l = { type = "op", op = op, l = l, r = r }
		end
		return l
	end
	local out = expr()
	if out and pos == #toks + 1 then
		return out
	end
	return nil
end

-- A whole equation packs into a short ASCII string: card indices 1-4,
-- operator codes and parentheses.
function Solver.eqTokensToString(toks: { Tok }): string
	local parts = {}
	for _, t in toks do
		if t.type == "card" then
			table.insert(parts, tostring(t.cardIdx))
		elseif t.type == "op" then
			table.insert(parts, t.op)
		else
			table.insert(parts, t.type)
		end
	end
	return table.concat(parts)
end

function Solver.parseEqString(s: string): { Tok }
	local toks = {}
	for i = 1, math.min(#s, 64) do
		local ch = string.sub(s, i, i)
		if ch == "(" or ch == ")" then
			table.insert(toks, { type = ch })
		elseif ch >= "1" and ch <= "4" then
			table.insert(toks, { type = "card", cardIdx = tonumber(ch) })
		elseif ch == "+" or ch == "-" or ch == "*" or ch == "/" then
			table.insert(toks, { type = "op", op = ch })
		else
			table.insert(toks, { type = "?" })
		end
	end
	return toks
end

-- Server-side verification of a claimed answer: every card exactly once,
-- well-formed, and exactly 24.
function Solver.verifyClaim(eq: any, cards: { Card }): boolean
	if typeof(eq) ~= "string" or #eq == 0 or #eq > 64 then
		return false
	end
	local toks = Solver.parseEqString(eq)
	local used = {}
	local count = 0
	for _, t in toks do
		if t.type == "?" then
			return false
		end
		if t.type == "card" then
			local i = t.cardIdx :: number
			if used[i] then
				return false
			end
			used[i] = true
			count += 1
		end
	end
	if count ~= 4 then
		return false
	end
	return Solver.is24(Solver.evaluate(toks, cards))
end

function Solver.validPuzzle(p: any): boolean
	if typeof(p) ~= "table" or #p ~= 4 then
		return false
	end
	for i = 1, 4 do
		local c = p[i]
		if typeof(c) ~= "table" or typeof(c.v) ~= "number" or typeof(c.s) ~= "number" then
			return false
		end
	end
	return true
end

return Solver

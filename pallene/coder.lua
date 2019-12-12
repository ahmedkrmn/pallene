local C = require "pallene.C"
local gc = require "pallene.gc"
local ir = require "pallene.ir"
local location = require "pallene.location"
local types = require "pallene.types"
local typedecl = require "pallene.typedecl"
local util = require "pallene.util"

local coder = {}

local Coder
local RecordCoder

function coder.generate(module, modname)
    local c = Coder.new(module, modname)
    local code = c:generate_module()
    return code, {}
end

--
-- #C-variables
--

-- @param typ : types.T
-- @returns the correspoinding C type, as a string.
local function ctype(typ)
    local tag = typ._tag
    if     tag == "types.T.Nil"      then return "int"
    elseif tag == "types.T.Boolean"  then return "int"
    elseif tag == "types.T.Integer"  then return "lua_Integer"
    elseif tag == "types.T.Float"    then return "lua_Number"
    elseif tag == "types.T.String"   then return "TString *"
    elseif tag == "types.T.Function" then return "TValue"
    elseif tag == "types.T.Array"    then return "Table *"
    elseif tag == "types.T.Table"    then return "Table *"
    elseif tag == "types.T.Record"   then return "Udata *"
    elseif tag == "types.T.Value"    then return "TValue"
    else error("impossible")
    end
end

-- @returns A syntactically valid function argument or variable declaration
--          without the comma or semicolon
local function c_declaration(typ, name)
    return string.format("%s %s", ctype(typ), name)
end

--
--
--

Coder = util.Class()
function Coder:init(module, modname)
    self.module = module
    self.modname = modname

    self.upvalues = {} -- { coder.Upvalue }
    self.upvalue_of_metatable = {} -- typ  => integer
    self.upvalue_of_string    = {} -- str  => integer
    self.upvalue_of_function  = {} -- f_id => integer
    self.upvalue_of_global    = {} -- g_id => integer
    self:init_upvalues()

    self.record_ids    = {}      -- types.T.Record => integer
    self.record_coders = {}      -- types.T.Record => RecordCoder
    for i, typ in ipairs(self.module.record_types) do
        self.record_ids[typ] = i
        self.record_coders[typ] = RecordCoder.new(self, typ)
    end

    self.gc = {} -- (see gc.compute_stack_slots)
    self.max_lua_call_stack_usage = {} -- func => integer
    self:init_gc()

    self.closures = {}      -- list of f_id
    self.closure_index = {} -- fid => index in closures lis
    self:init_closures()
end

--
-- #slots
--

-- @param src_slot: The TValue* to read from
local function get_slot(typ, src_slot)
    local tmpl
    local tag = typ._tag
    if     tag == "types.T.Nil"      then tmpl = "0"
    elseif tag == "types.T.Boolean"  then tmpl = "bvalue($src)"
    elseif tag == "types.T.Integer"  then tmpl = "ivalue($src)"
    elseif tag == "types.T.Float"    then tmpl = "fltvalue($src)"
    elseif tag == "types.T.String"   then tmpl = "tsvalue($src)"
    elseif tag == "types.T.Function" then tmpl = "*($src)"
    elseif tag == "types.T.Array"    then tmpl = "hvalue($src)"
    elseif tag == "types.T.Table"    then tmpl = "hvalue($src)"
    elseif tag == "types.T.Record"   then tmpl = "uvalue($src)"
    elseif tag == "types.T.Value"    then tmpl = "*($src)"
    else error("impossible")
    end
    return (util.render(tmpl, {src = src_slot}))
end

-- Set a TValue* slot that is in the Lua or C stack.
-- @param typ: type of source value
local function set_stack_slot(typ, dst_slot, value)
    local tmpl
    local tag = typ._tag
    if     tag == "types.T.Nil"      then tmpl = "pallene_setnilvalue($dst);"
    elseif tag == "types.T.Boolean"  then tmpl = "setbvalue($dst, $src);"
    elseif tag == "types.T.Integer"  then tmpl = "setivalue($dst, $src);"
    elseif tag == "types.T.Float"    then tmpl = "setfltvalue($dst, $src);"
    elseif tag == "types.T.String"   then tmpl = "setsvalue(L, $dst, $src);"
    elseif tag == "types.T.Function" then tmpl = "setobj(L, $dst, &$src);"
    elseif tag == "types.T.Array"    then tmpl = "sethvalue(L, $dst, $src);"
    elseif tag == "types.T.Table"    then tmpl = "sethvalue(L, $dst, $src);"
    elseif tag == "types.T.Record"   then tmpl = "setuvalue(L, $dst, $src);"
    elseif tag == "types.T.Value"    then tmpl = "setobj(L, $dst, &$src);"
    else error("impossible")
    end
    return (util.render(tmpl, { dst = dst_slot, src = value }))
end

-- Set a TValue* slot that belongs to some heap object (array, record, etc)
-- Needs to receive a pointer to the parent object, because of the GC write
-- barrier. See comments in pallene_core.h.
local function set_heap_slot(typ, dst_slot, value, parent)
    local lines = {}
    table.insert(lines, set_stack_slot(typ, dst_slot, value))

    if types.is_gc(typ) then
        local tmpl
        if typ._tag == "types.T.Value" or typ._tag == "types.T.Function" then
            tmpl = [[pallene_barrierback_unknown_child(L, $p, &$v); ]]
        else
            tmpl = [[pallene_barrierback_collectable_child(L, $p, $v); ]]
        end
        table.insert(lines, util.render(tmpl, { p = parent, v = value }))
    end

    return table.concat(lines, "\n")
end

function Coder:push_to_stack(typ, value)
    return (util.render([[
        ${set_stack_slot}
        api_incr_top(L);
    ]],{
        set_stack_slot = set_stack_slot(typ, "s2v(L->top)", value),
    }))
end

--
-- #tags
--

local function pallene_type_tag(typ)
    local tag = typ._tag
    if     tag == "types.T.Nil"      then return "LUA_TNIL"
    elseif tag == "types.T.Boolean"  then return "LUA_TBOOLEAN"
    elseif tag == "types.T.Integer"  then return "LUA_TNUMINT"
    elseif tag == "types.T.Float"    then return "LUA_TNUMFLT"
    elseif tag == "types.T.String"   then return "LUA_TSTRING"
    elseif tag == "types.T.Function" then return "LUA_TFUNCTION"
    elseif tag == "types.T.Array"    then return "LUA_TTABLE"
    elseif tag == "types.T.Table"    then return "LUA_TTABLE"
    elseif tag == "types.T.Record"   then return "LUA_TUSERDATA"
    elseif tag == "types.T.Value"    then error("value is not a tag")
    else error("impossible")
    end
end

function Coder:test_tag(typ, slot)
    local tmpl
    local tag = typ._tag
    if     tag == "types.T.Nil"      then tmpl = "ttisnil($slot)"
    elseif tag == "types.T.Boolean"  then tmpl = "ttisboolean($slot)"
    elseif tag == "types.T.Integer"  then tmpl = "ttisinteger($slot)"
    elseif tag == "types.T.Float"    then tmpl = "ttisfloat($slot)"
    elseif tag == "types.T.String"   then tmpl = "ttisstring($slot)"
    elseif tag == "types.T.Function" then tmpl = "ttisfunction($slot)"
    elseif tag == "types.T.Array"    then tmpl = "ttistable($slot)"
    elseif tag == "types.T.Table"    then tmpl = "ttistable($slot)"
    elseif tag == "types.T.Value"    then tmpl = "1"
    elseif tag == "types.T.Record"   then
        return (util.render([[(ttisfulluserdata($slot) && uvalue($slot)->metatable == hvalue($mt_slot))]], {
            slot = slot,
            mt_slot = self:metatable_upvalue_slot(typ),
        }))
    end
    return (util.render(tmpl, {slot = slot}))
end

-- Perform a run-time tag check
--
-- typ: expected type
-- slot: TValue* to be tested
-- loc: source code location (for error reporting)
-- description_fmt: Format string in lua_pushfstring format, which
--                  describes what this tag check is for.
--                  Received as a Lua string.
-- ... (extra_args): Parameters to the format string.
--                  Received as serialized C expressions.
function Coder:check_tag(typ, slot, loc, description_fmt, ...)
    if typ._tag == "types.T.Value" then
        return ""
    else
        local extra_args = table.pack(...)
        return (util.render([[
            if (PALLENE_UNLIKELY(!$test)) {
                pallene_runtime_tag_check_error(L,
                    $line, $expected_tag, rawtt($slot),
                    ${description_fmt}${opt_comma}${extra_args});
            }
        ]], {
            test = self:test_tag(typ, slot),
            line = C.integer(loc and loc.line or 0),
            expected_tag = pallene_type_tag(typ),
            slot = slot,
            description_fmt = C.string(description_fmt),
            opt_comma = (#extra_args == 0 and "" or ", "),
            extra_args = table.concat(extra_args, ", "),
        }))
    end
end

--
--  # Local variables
--

-- @returns the C variable name for the variable v_id
function Coder:c_var(v_id)
    return "x" .. v_id
end

-- @returns the C expression for an ir.Value
function Coder:c_value(value)
    local tag = value._tag
    if     tag == "ir.Value.Nil" then
        return "0"
    elseif tag == "ir.Value.Bool" then
        return C.boolean(value.value)
    elseif tag == "ir.Value.Integer" then
        return C.integer(value.value)
    elseif tag == "ir.Value.Float" then
        return C.float(value.value)
    elseif tag == "ir.Value.String" then
        local str = value.value
        return get_slot(
            types.T.String(),
            self:string_upvalue_slot(str))
    elseif tag == "ir.Value.LocalVar" then
        return self:c_var(value.id)
    elseif tag == "ir.Value.Function" then
        local f_id = value.id
        return get_slot(
            self.module.functions[f_id].typ,
            self:function_upvalue_slot(f_id))
    else
        error("impossible")
    end
end

-- @returns A syntactically valid function argument or variable declaration
--      for variable v_id from function f_id. If the variable has a name,
--      also includes it, as a C comment. Since this may be used for either
--      a local variable or a function argument, there is no semicolon.
function Coder:local_declaration(f_id, v_id)
    local decl = self.module.functions[f_id].vars[v_id]
    local name = self:c_var(v_id)
    local comment = decl.name and C.comment(decl.name) or ""
    return c_declaration(decl.typ, name), comment
end

--
-- # Pallene entry point
--
-- Pallene functions receive as parameters:
--  - Lua state (L)
--  - Global upvalues table (G)
--  - Regular parameters (x1, x2, x3...)
--
-- If the function returns no results, it returns void.
-- Otherwhise it returns its return value. Multiple returns are not implemented
--
-- It is assumed that the all arguments are saved in the Lua stack by the caller

function Coder:pallene_entry_point_name(f_id)
    return string.format("function_%02d", f_id)
end

function Coder:pallene_entry_point_declaration(f_id)
    local func = self.module.functions[f_id]
    local arg_types = func.typ.arg_types
    local ret_types = func.typ.ret_types
    assert(#ret_types <= 1)

    local ret_type = (#ret_types >= 1 and ctype(ret_types[1]) or "void")

    local args = {} -- { {name , comment} }
    table.insert(args, {"lua_State *L", ""})
    table.insert(args, {"Udata *G", ""})
    table.insert(args, {"StackValue *base", ""})
    for i = 1, #arg_types do
        local v_id = ir.arg_var(func, i)
        local decl, comment = self:local_declaration(f_id, v_id)
        table.insert(args, {decl, comment})
    end

    local arg_lines = {}
    for i, arg in ipairs(args) do
        local comma = (i < #args) and "," or " "
        table.insert(arg_lines, string.format("%s%s %s", arg[1], comma, arg[2]))
    end

    return (util.render([[
        static ${ret_type} ${name}(
            ${args}
        )]], { -- no whitespace after ")"
            ret_type = ret_type,
            name = self:pallene_entry_point_name(f_id),
            args = table.concat(arg_lines, "\n"),
        }))
end

function Coder:pallene_entry_point_definition(f_id)
    local func = self.module.functions[f_id]
    local arg_types = func.typ.arg_types
    local ret_types = func.typ.ret_types

    local name_comment = func.name
    if func.loc then
        name_comment = name_comment .. " " .. location.show_line(func.loc)
    end

    local prologue = {}
    local epilogue = {}

    local max_frame_size = self.gc[func].max_frame_size
    local slots_needed = max_frame_size + self.max_lua_call_stack_usage[func]
    if slots_needed > 0 then
        table.insert(prologue, util.render([[
            luaD_checkstack(L, $slots_needed);
        ]], {
            slots_needed = C.integer(slots_needed),
        }))
    end

    for v_id = #arg_types + 1, #func.vars do
        local decl, comment = self:local_declaration(f_id, v_id)
        table.insert(prologue, string.format("%s; %s", decl, comment))
    end

    local body = self:generate_cmd(func, func.body)

    if #ret_types == 0 then
        table.insert(epilogue, "return;")
    else
        local v = self:c_var(ir.ret_var(func, 1))
        table.insert(epilogue, string.format("return %s;", v))
    end

    return (util.render([[
        ${name_comment}
        ${fun_decl} {
            ${prologue}

            /**/

            ${body}

            /**/

          done:
            ${epilogue}
        }
    ]], {
        name_comment = C.comment(name_comment),
        fun_decl = self:pallene_entry_point_declaration(f_id),
        prologue = table.concat(prologue, "\n"),
        body = body,
        epilogue = table.concat(epilogue, "\n"),
    }))
end

function Coder:call_pallene_function(dst, f_id, base, xs)
    local func = self.module.functions[f_id]
    local ret_types = func.typ.ret_types

    local args = {}
    table.insert(args, "L")
    table.insert(args, "G")
    table.insert(args, base)
    for _, x in ipairs(xs) do
        table.insert(args, x)
    end

    local call = util.render([[$name($args);]], {
        name = self:pallene_entry_point_name(f_id),
        args = table.concat(args, ", "),
    })

    if #ret_types == 0 then
        assert(dst == false)
        return call
    else
        assert(dst)
        return (util.render([[$dst = $call]], {
            dst = dst,
            call = call,
        }))
    end
end

--
-- # Lua entry point
--
-- Lua interface to a pallene function. Used when Lua is calling pallene
-- functions, or when Pallene is calling a variable of function type.
--
-- The first upvalue should be the module's global userdata object.


-- Computes a list of function ids that need a Lua entry point
function Coder:init_closures()
    local f_ids = {}
    table.insert(f_ids, 1) -- $init function
    for f_id in pairs(self.upvalue_of_function) do
        table.insert(f_ids, f_id)
    end
    for _, f_id in ipairs(self.module.exports) do
        table.insert(f_ids, f_id)
    end
    table.sort(f_ids) -- For determinism

    for _, f_id in ipairs(f_ids) do
        if not self.closure_index[f_id] then
            table.insert(self.closures, f_id)
            self.closure_index[f_id] = #self.closures
        end
    end
end

function Coder:lua_entry_point_name(f_id)
    return string.format("function_%02d_lua", f_id)
end

function Coder:lua_entry_point_declaration(f_id)
    return (util.render([[static int ${name}(lua_State *L)]], {
        name = self:lua_entry_point_name(f_id)
    }))
end

function Coder:lua_entry_point_definition(f_id)
    local func = self.module.functions[f_id]
    local fname = func.name
    local arg_types = func.typ.arg_types
    local ret_types = func.typ.ret_types

    -- We unconditionally initialize the G userdata here, in case one of the tag
    -- checking tests needs to use it. We don't bother to make this
    -- initialization conditional because in the case that really matters (small
    -- leaf functions that don't use G) the C compiler can optimize this read
    -- away after inlining the Pallene entry point.
    local init_global_userdata = [[
        CClosure *func = clCvalue(s2v(base));
        Udata *G = uvalue(&func->upvalue[0]);
    ]]

    local arity_check = util.render([[
        int nargs = lua_gettop(L);
        if (PALLENE_UNLIKELY(nargs != $nargs)) {
            pallene_runtime_arity_error(L, $fname, $nargs, nargs);
        }
    ]], {
        nargs = C.integer(#arg_types),
        fname = C.string(fname),
    })


    local type_checks = {}
    for i, typ in ipairs(arg_types) do
        local name = func.vars[i].name
        local check_tag =
            self:check_tag(typ, "slot", func.loc, "argument %s", C.string(name))
        if check_tag ~= ""  then
            table.insert(type_checks, util.render([[
                slot = s2v(base + $i);
                ${check_tag}
            ]], {
                i = C.integer(i),
                check_tag = check_tag,
            }))
        end
    end

    local base = "L->top"

    local arg_vars = {}
    local init_args = {}
    for i, typ in ipairs(arg_types) do
        local slot = string.format("s2v(base + %s)", C.integer(i))
        local name = "x"..i
        arg_vars[i] = name
        table.insert(init_args, util.render([[
            $decl = $get_slot;
        ]], {
            decl = c_declaration(typ, name),
            get_slot = get_slot(typ, slot),
        }))
    end

    local ret_vars = {}
    local ret_decls = {}
    for i, typ in ipairs(ret_types) do
        local ret = string.format("ret%d", i)
        table.insert(ret_vars, ret)
        table.insert(ret_decls, c_declaration(typ, ret)..";")
    end

    local call_pallene
    if #ret_types == 0 then
        call_pallene = self:call_pallene_function(false, f_id, base, arg_vars)
    else
        call_pallene = self:call_pallene_function(ret_vars[1], f_id, base, arg_vars)
    end

    local return_results = {}
    for i, typ in ipairs(ret_types) do
        table.insert(return_results, self:push_to_stack(typ, ret_vars[i]))
    end
    table.insert(return_results,
        string.format("return %s;", C.integer(#ret_types)))

    return (util.render([[
        ${fun_decl}
        {
            StackValue *base = L->ci->func;
            TValue *slot;
            /**/
            ${init_global_userdata}
            /**/
            ${arity_check}
            /**/
            ${type_checks}
            /**/
            ${init_args}
            ${ret_decls}
            ${call_pallene}
            ${return_results}
        }
    ]], {
        fun_decl = self:lua_entry_point_declaration(f_id),
        init_global_userdata = init_global_userdata,
        arity_check = arity_check,
        type_checks = table.concat(type_checks, "\n"),
        init_args = table.concat(init_args, "\n"),
        ret_decls = table.concat(ret_decls, "\n"),
        call_pallene = call_pallene,
        return_results = table.concat(return_results, "\n"),
    }))
end

--
-- # Global coder
--
-- This section of the program is responsible for keeping track of the
-- "global" values in the module that need to be seen from every function.
-- We store them in the uservalues of an userdata object.

typedecl.declare(coder, "coder", "Upvalue", {
    Metatable = {"typ"},
    String = {"str"},
    Function = {"f_id"},
    Global = {"g_id"},
})

function Coder:init_upvalues()

    -- Metatables
    for _, typ in ipairs(self.module.record_types) do
        table.insert(self.upvalues, coder.Upvalue.Metatable(typ))
        self.upvalue_of_metatable[typ] = #self.upvalues
    end

    -- String Literals
    for _, func in ipairs(self.module.functions) do
        for cmd in ir.iter(func.body) do
            for _, v in ipairs(ir.get_srcs(cmd)) do
                if v._tag == "ir.Value.String" then
                    local str = v.value
                    table.insert(self.upvalues, coder.Upvalue.String(str))
                    self.upvalue_of_string[str] = #self.upvalues
                end
            end
        end
    end

    -- Functions
    for _, func in ipairs(self.module.functions) do
        for cmd in ir.iter(func.body) do
            for _, v in ipairs(ir.get_srcs(cmd)) do
                if v._tag == "ir.Value.Function" then
                    local f_id = v.id
                    table.insert(self.upvalues, coder.Upvalue.Function(f_id))
                    self.upvalue_of_function[f_id] = #self.upvalues
                end
            end
        end
    end

    -- Globals
    for g_id = 1, #self.module.globals do
        table.insert(self.upvalues, coder.Upvalue.Global(g_id))
        self.upvalue_of_global[g_id] = #self.upvalues
    end
end

local function upvalue_slot(ix)
    return string.format("&G->uv[%s].uv", C.integer(ix - 1))
end

function Coder:metatable_upvalue_slot(typ)
    local ix = assert(self.upvalue_of_metatable[typ])
    return upvalue_slot(ix)
end

function Coder:string_upvalue_slot(str)
    local ix = assert(self.upvalue_of_string[str])
    return upvalue_slot(ix)
end

function Coder:function_upvalue_slot(f_id)
    local ix = assert(self.upvalue_of_function[f_id])
    return upvalue_slot(ix)
end

function Coder:global_upvalue_slot(g_id)
    local ix = assert(self.upvalue_of_global[g_id])
    return upvalue_slot(ix)
end

--
-- # Records
--
-- Records are implemented as full userdata.
--
-- The primitive-typed fields are represented as raw C values, and stored in a
-- struct in the block of raw memory of the userdata.
--
-- The GC-typed fields are represented as tagged TValues, and stored as
-- uservalues. (We need the tags because function values need the tag variants)

RecordCoder = util.Class()
function RecordCoder:init(owner, record_typ)
    local gc_count = 0
    local gc_index = {}
    local prim_count = 0
    local prim_index = {}
    for _, field_name in ipairs(record_typ.field_names) do
        local typ = record_typ.field_types[field_name]
        if types.is_gc(typ) then
            gc_count = gc_count + 1
            gc_index[field_name] = gc_count
        else
            prim_count = prim_count + 1
            prim_index[field_name] = prim_count
        end
    end

    self.owner = owner            -- Coder
    self.record_typ = record_typ  -- types.T.Record
    self.gc_count = gc_count      -- integer
    self.gc_index = gc_index      -- map string => integer
    self.prim_count = prim_count  -- integer
    self.prim_index = prim_index  -- map string => integer
end

function RecordCoder:struct_name()
    assert(self.prim_count > 0)
    local r_id = self.owner.record_ids[self.record_typ]
    return string.format("crecord_%02d", r_id)
end

function RecordCoder:get_prims_name()
    assert(self.prim_count > 0)
    local r_id = self.owner.record_ids[self.record_typ]
    return string.format("crecord_%02d_prims", r_id)
end

function RecordCoder:field_name(name)
    local i = assert(self.prim_index[name])
    return string.format("f%02d", i)
end

function RecordCoder:prims_sizeof()
    if self.prim_count > 0 then
        return string.format("sizeof(%s)", self:struct_name())
    else
        return C.integer(0)
    end
end

function RecordCoder:constructor_name()
    local r_id = self.owner.record_ids[self.record_typ]
    return string.format("crecord_%02d_new", r_id)
end

function RecordCoder:declarations()
    local declarations = {}

    -- Comment
    table.insert(declarations, C.comment(self.record_typ.name) .. "\n")

    -- Struct for the primitive fields.
    -- (C does not allow empty structs so we skip in that case)
    if self.prim_count > 0 then

        local struct_name = self:struct_name()

        local field_lines = {}
        for _, field_name in ipairs(self.record_typ.field_names) do
            local typ = self.record_typ.field_types[field_name]
            if not types.is_gc(typ) then
                local name = self:field_name(field_name)
                local decl = c_declaration(typ, name)
                local cmt = C.comment(field_name)
                table.insert(field_lines, string.format("%s; %s", decl, cmt))
            end
        end

        table.insert(declarations, util.render([[
            typedef struct {
                ${field_lines}
            } $struct_name;
        ]], {
            struct_name = struct_name,
            field_lines = table.concat(field_lines, "\n"),
        }))

        table.insert(declarations, util.render([[
            inline
            static ${struct_name} *${get_prims}(Udata *u)
            {
                char *p = cast_charp(u) + udatamemoffset($gc_count);
                return (${struct_name} *) p;
            }
        ]], {
            struct_name = struct_name,
            get_prims = self:get_prims_name(),
            gc_count = C.integer(self.gc_count),
        }))
    end

    -- Constructor
    table.insert(declarations, util.render([[
        static Udata *${constructor_name}(lua_State *L, Udata *G)
        {
            Udata *rec = luaS_newudata(L, $prims_sizeof, $nvalues);
            rec->metatable = hvalue($mt_slot);
            return rec;
        }
    ]], {
        constructor_name = self:constructor_name(),
        prims_sizeof = self:prims_sizeof(),
        nvalues = C.integer(self.gc_count),
        mt_slot = self.owner:metatable_upvalue_slot(self.record_typ),
    }))

    return table.concat(declarations, "\n")
end

function RecordCoder:get_prim_lvalue(rec_cvar, field_name)
    local _ = assert(self.prim_index[field_name])
    return (util.render([[$get_prims($udata)->$f]], {
        get_prims = self:get_prims_name(),
        udata = rec_cvar,
        f = self:field_name(field_name),
    }))
end

function RecordCoder:get_gc_slot(rec_cvar, field_name)
    local ix = assert(self.gc_index[field_name])
    return (util.render([[&$udata->uv[$i].uv]], {
        udata = rec_cvar,
        i = C.integer(ix - 1),
    }))
end

--
-- # GC Stuff
--

function Coder:init_gc()

    for _, func in ipairs(self.module.functions) do
        self.gc[func] = gc.compute_stack_slots(func)
    end

    for _, func in ipairs(self.module.functions) do
        local max = 0
        for cmd in ir.iter(func.body) do
            if cmd._tag == "ir.Cmd.CallDyn" then
                local nsrcs = #cmd.srcs
                local ndst  = 1
                max = math.max(max, nsrcs+1, ndst)
            end
        end
        self.max_lua_call_stack_usage[func] = max
    end
end

--
-- # Call stack managements
--

function Coder:stack_top_at(func, cmd)
    local offset = 0
    for _, v_id in ipairs(self.gc[func].live_gc_vars[cmd]) do
        local slot = self.gc[func].slot_of_variable[v_id]
        offset = math.max(offset, slot + 1)
    end

    return util.render("base + $offset", { offset = C.integer(offset) })
end

function Coder:wrap_function_call(call_stats)
    return util.render([[
        {
            StackValue *old_stack = L->stack;
            ${call_stats}
            base = L->stack + (base - old_stack);
        }
    ]], {
        call_stats = call_stats,
    })
end

--
-- # Generate Cmd
--

local gen_cmd = {}

gen_cmd["Move"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local src = self:c_value(cmd.src)
    return (util.render([[ $dst = $src; ]], { dst = dst, src = src }))
end

gen_cmd["GetGlobal"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local g_id = cmd.global_id
    local typ = self.module.globals[g_id].typ
    return (util.render([[ $dst = $get_slot; ]], {
        dst = dst,
        get_slot = get_slot(typ, self:global_upvalue_slot(g_id)),
    }))
end

gen_cmd["SetGlobal"] = function(self, cmd, _func)
    local src = self:c_value(cmd.src)
    local g_id = cmd.global_id
    local typ = self.module.globals[g_id].typ
    return (set_heap_slot(typ, self:global_upvalue_slot(g_id), src, "G"))
end

gen_cmd["Unop"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local x = self:c_value(cmd.src)

    -- For when we can be directly translate to a C operator:
    local function unop(op)
        return (util.render([[ $dst = ${op}$x; ]], {
            op = op , dst = dst, x = x }))
    end

    local function int_neg()
        return (util.render([[ $dst = intop(-, 0, $x); ]], {
            dst = dst, x = x }))
    end

    local function arr_len()
        return (util.render([[ $dst = luaH_getn($x); ]], {
            dst = dst, x = x }))
    end

    local function str_len()
        return (util.render([[ $dst = tsslen($x); ]], {
            dst = dst, x = x }))
    end

    local op = cmd.op
    if     op == "ArrLen"  then return arr_len()
    elseif op == "StrLen"  then return str_len()
    elseif op == "IntNeg"  then return int_neg()
    elseif op == "FltNeg"  then return unop("-")
    elseif op == "BitNeg"  then return unop("~")
    elseif op == "BoolNot" then return unop("!")
    else
        error("impossible")
    end
end

gen_cmd["Binop"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local x = self:c_value(cmd.src1)
    local y = self:c_value(cmd.src2)

    -- For when we can be directly translate to a C operator:
    local function binop(op)
        return (util.render([[ $dst = $x $op $y; ]], {
            op = op, dst = dst, x = x, y = y }))
    end

    -- For relational ops, which look better with extra parens:
    local function binop_paren(op)
        return (util.render([[ $dst = ($x $op $y); ]], {
            op = op, dst = dst, x = x, y = y }))
    end

    -- For integer ops with two's-complement wraparound:
    local function int_binop(op)
        return (util.render([[ $dst = intop($op, $x, $y); ]], {
            op = op, dst = dst, x = x, y = y }))
    end

    -- For integer division and modulus:
    local function int_division(fname)
        local line = cmd.loc.line
        return (util.render([[ $dst = $fname(L, $x, $y, $line); ]], {
            fname = fname, dst = dst, x = x, y = y, line = C.integer(line) }))
    end

    local function flt_divi()
        return (util.render([[ $dst = floor($x / $y); ]], {
            dst = dst, x = x, y = y }))
    end

    local function flt_mod()
        -- See luai_nummod
        error("not implemented (float mod)")
    end

    -- For integer shift:
    local function shift(fname)
        return (util.render([[ $dst = $fname($x, $y); ]], {
            fname = fname, dst = dst, x = x, y = y }))
    end

    local function pow()
       return (util.render([[ $dst = pow($x, $y); ]], {
            dst = dst, x = x, y = y }))
    end

    local function strcmp(op)
        return (util.render([[ $dst = (pallene_l_strcmp($x, $y) $op 0); ]], {
            dst = dst, x = x, y = y, op = op }))
    end

    local op = cmd.op
    if     op == "IntAdd"    then return int_binop("+")
    elseif op == "IntSub"    then return int_binop("-")
    elseif op == "IntMul"    then return int_binop("*")
    elseif op == "IntDivi"   then return int_division("pallene_int_divi")
    elseif op == "IntMod"    then return int_division("pallene_int_modi")
    elseif op == "FltAdd"    then return binop("+")
    elseif op == "FltSub"    then return binop("-")
    elseif op == "FltMul"    then return binop("*")
    elseif op == "FltDivi"   then return flt_divi()
    elseif op == "FltMod"    then return flt_mod()
    elseif op == "FltDiv"    then return binop("/")
    elseif op == "BitAnd"    then return int_binop("&")
    elseif op == "BitOr"     then return int_binop("|")
    elseif op == "BitXor"    then return int_binop("^")
    elseif op == "BitLShift" then return shift("pallene_shiftL")
    elseif op == "BitRShift" then return shift("pallene_shiftR")
    elseif op == "FltPow"    then return pow()
    elseif op == "IntEq"     then return binop_paren("==")
    elseif op == "IntNeq"    then return binop_paren("!=")
    elseif op == "IntLt"     then return binop_paren("<")
    elseif op == "IntGt"     then return binop_paren(">")
    elseif op == "IntLeq"    then return binop_paren("<=")
    elseif op == "IntGeq"    then return binop_paren(">=")
    elseif op == "FltEq"     then return binop_paren("==")
    elseif op == "FltNeq"    then return binop_paren("!=")
    elseif op == "FltLt"     then return binop_paren("<")
    elseif op == "FltGt"     then return binop_paren(">")
    elseif op == "FltLeq"    then return binop_paren("<=")
    elseif op == "FltGeq"    then return binop_paren(">=")
    elseif op == "StrEq"     then return strcmp("==")
    elseif op == "StrNeq"    then return strcmp("!=")
    elseif op == "StrLt"     then return strcmp("<")
    elseif op == "StrGt"     then return strcmp(">")
    elseif op == "StrLeq"    then return strcmp("<=")
    elseif op == "StrGeq"    then return strcmp(">=")
    elseif op == "BoolEq"    then return binop_paren("==")
    elseif op == "BoolNeq"   then return binop_paren("!=")
    else
        print("OP=", op)
        error("impossible")
    end
end

gen_cmd["Concat"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)

    local init_input_array = {}
    for ix, srcv in ipairs(cmd.srcs) do
        local src = self:c_value(srcv)
        table.insert(init_input_array,
            util.render([[ ss[$i] = $src; ]], {
                i = C.integer(ix - 1),
                src = src,
            }))
    end

    return (util.render([[
        {
            TString *ss[$N];
            ${init_input_array};
            $dst = pallene_string_concatN(L, $N, ss);
        }
    ]], {
        dst = dst,
        N = C.integer(#cmd.srcs),
        init_input_array = table.concat(init_input_array, "\n"),
    }))
end

gen_cmd["ToDyn"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local src = self:c_value(cmd.src)
    local src_typ = cmd.src_typ
    return (set_stack_slot(src_typ, "&"..dst, src))
end

gen_cmd["FromDyn"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local src = self:c_value(cmd.src)
    local dst_typ = cmd.dst_typ
    return (util.render([[
        ${check_tag}
        $dst = $get_slot;
    ]], {
        dst = dst,
        check_tag = self:check_tag(dst_typ, "&"..src,
                cmd.loc, "downcasted value"),
        get_slot = get_slot(dst_typ, "&"..src),
    }))
end

gen_cmd["IsTruthy"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local src = self:c_value(cmd.src)
    return (util.render([[ $dst = pallene_is_truthy(&$src); ]], {
        dst = dst, src = src }))
end

gen_cmd["NewArr"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local n = C.integer(cmd.size_hint)
    return (util.render([[ $dst = pallene_new_array(L, $n); ]], {
        dst = dst, n = n,
    }))
end

gen_cmd["GetArr"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local arr = self:c_value(cmd.src_arr)
    local i   = self:c_value(cmd.src_i)
    local dst_typ = cmd.dst_typ
    local line = C.integer(cmd.loc.line)

    local fix_nils = ""
    if dst_typ._tag == "types.T.Value" then
        -- Remove "EMPTY" variant tag from out-of-bound nils
        -- note: rawget in lapi.c also needs to do this.
        -- note: pallene_setnilvalue not needed since dst is already initialized
        fix_nils = util.render([[
            if (isempty(&$dst)) { setnilvalue(&$dst); }
        ]], {
            dst = dst
        })
    end

    return (util.render([[
        {
            pallene_renormalize_array(L, $arr, $i, $line);
            TValue *slot = &$arr->array[$i - 1];
            ${check_tag}
            $dst = $get_slot;
            ${fix_nils}
        }
    ]], {
        dst = dst,
        arr = arr,
        i = i,
        line = line,
        check_tag = self:check_tag(dst_typ, "slot", cmd.loc, "array element"),
        get_slot = get_slot(dst_typ, "slot"),
        fix_nils = fix_nils,
    }))
end

gen_cmd["SetArr"] = function(self, cmd, _func)
    local arr = self:c_value(cmd.src_arr)
    local i   = self:c_value(cmd.src_i)
    local v   = self:c_value(cmd.src_v)
    local src_typ = cmd.src_typ
    local line = C.integer(cmd.loc.line)
    return (util.render([[
        {
            pallene_renormalize_array(L, $arr, $i, $line);
            TValue *slot = &$arr->array[$i - 1];
            ${set_heap_slot}
        }
    ]], {
        arr = arr,
        i = i,
        v = v,
        line = line,
        set_heap_slot = set_heap_slot(src_typ, "slot", v, arr),
    }))
end

gen_cmd["NewTable"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local n = C.integer(cmd.size_hint)
    return (util.render([[ $dst = pallene_new_table(L, $n); ]], {
        dst = dst,
        n = n,
    }))
end

gen_cmd["GetTable"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local tab = self:c_value(cmd.src_tab)
    local key = self:c_value(cmd.src_k)
    local dst_typ = cmd.dst_typ
    local line = C.integer(cmd.loc.line)

    return (util.render([[
        {
            static int cache = 0;
            TValue *slot = pallene_getstr($tab, $key, &cache);
            ${check_tag}
            $dst = $get_slot;
        }
    ]], {
        dst = dst,
        tab = tab,
        key = key,
        line = line,
        check_tag = self:check_tag(dst_typ, "slot", cmd.loc, "table field"),
        get_slot = get_slot(dst_typ, "slot"),
    }))
end

gen_cmd["SetTable"] = function(self, cmd, _func)
    local tab = self:c_value(cmd.src_tab)
    local key = self:c_value(cmd.src_k)
    local v = self:c_value(cmd.src_v)
    local src_typ = cmd.src_typ
    local line = C.integer(cmd.loc.line)
    return (util.render([[
        {
            static int cache = 0;
            TValue *slot = pallene_getstr($tab, $key, &cache);
            if (PALLENE_UNLIKELY(isabstkey(slot))) {
                TValue keyv;
                setsvalue(L, &keyv, $key);
                slot = luaH_newkey(L, $tab, &keyv);
            }
            ${set_heap_slot}
        }
    ]], {
        tab = tab,
        key = key,
        line = line,
        set_heap_slot = set_heap_slot(src_typ, "slot", v, tab),
    }))
end

gen_cmd["NewRecord"] = function(self, cmd, _func)
    local rc = self.record_coders[cmd.rec_typ]
    local rec = self:c_var(cmd.dst)
    return (util.render([[$rec = $constructor(L, G);]] , {
            rec = rec,
            constructor = rc:constructor_name(),
        }))
end

gen_cmd["GetField"] = function(self, cmd, _func)
    local rec_typ = cmd.rec_typ
    local rc = self.record_coders[rec_typ]

    local dst = self:c_var(cmd.dst)
    local rec = self:c_value(cmd.src_rec)
    local field_name = cmd.field_name

    local f_typ = rec_typ.field_types[field_name]
    local result
    if types.is_gc(f_typ) then
        local slot = rc:get_gc_slot(rec, field_name)
        result = get_slot(f_typ, slot)
    else
        result = rc:get_prim_lvalue(rec, field_name)
    end

    return (util.render([[$dst = $result;]], { dst = dst, result = result }))
end

gen_cmd["SetField"] = function(self, cmd, _func)
    local rec_typ = cmd.rec_typ
    local rc = self.record_coders[rec_typ]

    local rec = self:c_value(cmd.src_rec)
    local v   = self:c_value(cmd.src_v)
    local field_name = cmd.field_name

    local f_typ = rec_typ.field_types[field_name]
    if types.is_gc(f_typ) then
        local slot = rc:get_gc_slot(rec, field_name)
        return (set_heap_slot(f_typ, slot, v, rec))
    else
        local lval = rc:get_prim_lvalue(rec, field_name)
        return (util.render([[$lval = $v;]], { lval = lval, v = v }))
    end
end

gen_cmd["CallStatic"] = function(self, cmd, func)
    local dst = cmd.dst and self:c_var(cmd.dst)
    local xs = {}
    for _, x in ipairs(cmd.srcs) do
        table.insert(xs, self:c_value(x))
    end
    local top = self:stack_top_at(func, cmd)
    local call_stats = self:call_pallene_function(dst, cmd.f_id, top, xs)
    return self:wrap_function_call(call_stats)
end

gen_cmd["CallDyn"] = function(self, cmd, func)
    local f_typ = cmd.f_typ
    local dst = cmd.dst and self:c_var(cmd.dst)

    local push_to_stack = {}
    table.insert(push_to_stack,
        set_stack_slot(f_typ, "s2v(L->top++)", self:c_value(cmd.src_f)))
    for i = 1, #f_typ.arg_types do
        local typ = f_typ.arg_types[i]
        table.insert(push_to_stack,
            set_stack_slot(typ, "s2v(L->top++)", self:c_value(cmd.srcs[i])))
    end

    local pop_from_stack = {}
    if dst then
        assert(#f_typ.ret_types == 1)
        local typ = f_typ.ret_types[1]
        table.insert(pop_from_stack, util.render([[
            $dst = $get_slot;]], {
                dst = dst,
                get_slot = get_slot(typ, "s2v(--L->top)") }))
    end

    local top = self:stack_top_at(func, cmd)
    local call_stats = util.render([[
        L->top = $top;
        ${push_to_stack}
        lua_call(L, $nargs, $nrets);
        ${pop_from_stack}
    ]], {
        top = top,
        push_to_stack = table.concat(push_to_stack, "\n"),
        pop_from_stack = table.concat(pop_from_stack, "\n"),
        nargs = C.integer(#f_typ.arg_types),
        nrets = C.integer(#f_typ.ret_types),
    })
    return self:wrap_function_call(call_stats)
end

gen_cmd["BuiltinIoWrite"] = function(self, cmd, _func)
    local v = self:c_value(cmd.src)
    return util.render([[ pallene_io_write(L, $v); ]], { v = v })
end

gen_cmd["BuiltinMathSqrt"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local v = self:c_value(cmd.src)
    return util.render([[ $dst = sqrt($v); ]], { dst = dst, v = v })
end

gen_cmd["BuiltinStringChar"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local v = self:c_value(cmd.src)
    local line = cmd.loc.line
    return util.render([[ $dst = pallene_string_char(L, $v, $line); ]], {
        dst = dst, v = v, line = C.integer(line) })
end

gen_cmd["BuiltinStringSub"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local str = self:c_value(cmd.src1)
    local i   = self:c_value(cmd.src2)
    local j   = self:c_value(cmd.src3)
    return util.render([[ $dst = pallene_string_sub(L, $str, $i, $j); ]], {
        dst = dst, str = str, i = i, j = j })
end

gen_cmd["BuiltinToFloat"] = function(self, cmd, _func)
    local dst = self:c_var(cmd.dst)
    local v = self:c_value(cmd.src)
    return util.render([[ $dst = (lua_Number) $v; ]], { dst = dst, v = v })
end


--
-- Control flow
--

gen_cmd["Nop"] = function(self, _cmd, _func)
    return ""
end

gen_cmd["Seq"] = function(self, cmd, func)
    local out = {}
    for _, c in ipairs(cmd.cmds) do
        table.insert(out, self:generate_cmd(func, c))
    end
    return table.concat(out, "\n")
end

gen_cmd["Return"] = function(self, _cmd)
    return [[ goto done; ]]
end

gen_cmd["Break"] = function(self, _cmd, _func)
    return [[ break; ]]
end

gen_cmd["If"] = function(self, cmd, func)
    local condition = self:c_value(cmd.condition)
    local then_ = self:generate_cmd(func, cmd.then_)
    local else_ = self:generate_cmd(func, cmd.else_)

    local A = (then_ ~= "")
    local B = (else_ ~= "")

    if  A and B then
        return (util.render([[
            if ($condition) {
                ${then_}
            } else {
                ${else_}
            }
        ]], {
            condition = condition,
            then_ = then_,
            else_ = else_,
        }))

    elseif A and (not B) then
        return (util.render([[
            if ($condition) {
                ${then_}
            }
        ]], {
            condition = condition,
            then_ = then_,
        }))

    elseif (not A) and B then
        return (util.render([[
            if (!$condition) {
                ${else_}
            }
        ]], {
            condition = condition,
            else_ = else_,
        }))

    else -- (not A) and (not B)
        -- ir.Clean does not allow this case.
        error("impossible")
    end
end

gen_cmd["Loop"] = function(self, cmd, func)
    local body = self:generate_cmd(func, cmd.body)
    return (util.render([[
        while (1) {
            ${body}
        }
    ]], {
        body = body
    }))
end

local for_counter = 0
gen_cmd["For"] = function(self, cmd, func)
    local typ = cmd.typ

    -- Use a unique name for the loop variables, to avoid Wshaadow warning
    for_counter = for_counter + 1
    local start = string.format("start%02d", for_counter)
    local limit = string.format("limit%02d", for_counter)
    local step  = string.format("step%02d", for_counter)

    local initialize = util.render(
        [[$ctyp $start = $startv, $limit = $limitv, $step = $stepv]], {
            ctyp = ctype(typ),
            start = start, limit = limit, step = step,
            startv = self:c_value(cmd.start),
            limitv = self:c_value(cmd.limit),
            stepv  = self:c_value(cmd.step),
        })

    local condition = util.render(
        [[($step >= 0 ? $start <= $limit : $start >= $limit)]], {
            start = start, limit = limit, step = step
        })

    local update_tmpl
    if     typ._tag == "types.T.Integer" then
        update_tmpl = [[ $start = intop(+, $start, $step) ]]
    elseif typ._tag == "types.T.Float" then
        update_tmpl = [[ $start = $start + $step ]]
    else
        error("impossible")
    end

    local update = util.render(update_tmpl, {
        start = start, limit = limit, step = step
    })

    local body = self:generate_cmd(func, cmd.body)

    return (util.render([[
        for(
            ${initialize};
            ${condition};
            ${update}
        ){
            $loopvar = $start;
            ${body}
        }
    ]], {
        loopvar = self:c_var(cmd.loop_var),
        start = start,
        initialize = initialize,
        condition = condition,
        update = update,
        body = body,
    }))
end

gen_cmd["CheckGC"] = function(self, cmd, func)
    local top = self:stack_top_at(func, cmd)
    return util.render([[ luaC_condGC(L, L->top = $top, (void)0); ]], {
        top = top })
end

function Coder:generate_cmd(func, cmd)
    local name = assert(string.match(cmd._tag, "^ir%.Cmd%.(.*)$"))
    local f = assert(gen_cmd[name], "impossible")
    local out = f(self, cmd, func)

    for _, v_id in ipairs(ir.get_dsts(cmd)) do
        local n = self.gc[func].slot_of_variable[v_id]
        if n then
            local typ = func.vars[v_id].typ
            local slot = util.render([[s2v(base + $n)]], { n = C.integer(n) })
            out = out .. "\n" .. set_stack_slot(typ, slot, self:c_var(v_id))
        end
    end

    return out
end

--
-- # Generate file
--

local function section_comment(msg)
    local ruler = string.rep("-", #msg)
    local lines = {}
    table.insert(lines, "")
    table.insert(lines, "/* " .. ruler .. " */")
    table.insert(lines, "/* " .. msg   .. " */")
    table.insert(lines, "/* " .. ruler .. " */")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

function Coder:generate_module()

    local out = {}

    table.insert(out, [[
        /* This file was generated by the Pallene compiler. Do not edit by hand" */
        /* Indentation and formatting courtesy of pallene/C.lua */

        #include "pallene_core.h"
    ]])

    table.insert(out, section_comment("Records"))
    for _, typ in ipairs(self.module.record_types) do
        local rc = self.record_coders[typ]
        table.insert(out, rc:declarations())
    end

    table.insert(out, section_comment("Function Prototypes"))
    for f_id = 1, #self.module.functions do
        table.insert(out, self:pallene_entry_point_declaration(f_id) .. ";")
    end

    table.insert(out, section_comment("Function Implementations"))
    for f_id = 1, #self.module.functions do
        table.insert(out, self:pallene_entry_point_definition(f_id))
    end

    table.insert(out, section_comment("Exports"))
    for _, f_id in ipairs(self.closures) do
        table.insert(out, self:lua_entry_point_definition(f_id))
    end
    table.insert(out, self:generate_luaopen_function())

    return C.reformat(table.concat(out, "\n"))
end

function Coder:generate_luaopen_function()

    local init_closures = {}
    for ix, f_id in ipairs(self.closures) do
        local entry_point = self:lua_entry_point_name(f_id)
        table.insert(init_closures, util.render([[
            lua_pushvalue(L, globals);
            lua_pushcclosure(L, ${entry_point}, 1);
            lua_seti(L, closures, $ix);
            /**/
        ]], {
            entry_point = entry_point,
            ix = C.integer(ix),
        }))
    end


    local init_upvalues = {}
    for ix, upv in ipairs(self.upvalues) do
        local tag = upv._tag
        if tag ~= "coder.Upvalue.Global" then
            if     tag == "coder.Upvalue.Metatable" then
                table.insert(init_upvalues, [[
                    lua_newtable(L);
                    lua_pushstring(L, "__metatable");
                    lua_pushboolean(L, 0);
                    lua_settable(L, -3); ]])
            elseif tag == "coder.Upvalue.String" then
                table.insert(init_upvalues, util.render([[
                    lua_pushstring(L, $str);]], {
                        str = C.string(upv.str)
                    }))
            elseif tag == "coder.Upvalue.Function" then
                table.insert(init_upvalues, util.render([[
                    lua_geti(L, closures, $ix); ]], {
                        ix = C.integer(self.closure_index[upv.f_id])
                    }))
            else
                error("impossible")
            end

            table.insert(init_upvalues, util.render([[
                lua_setiuservalue(L, globals, $ix);
                /**/
            ]], {
                ix = C.integer(ix),
            }))
        end
    end
    table.insert(init_upvalues, [[
        // Run toplevel statements & initialize globals
        lua_geti(L, closures, 1);
        lua_call(L, 0, 0);
    ]])


    local init_exports = {}
    for _, f_id in ipairs(self.module.exports) do
        local name = self.module.functions[f_id].name
        table.insert(init_exports, util.render([[
            lua_pushstring(L, ${name});
            lua_geti(L, closures, $ix);
            lua_settable(L, export_table);
            /**/
        ]], {
            name = C.string(name),
            ix = C.integer(self.closure_index[f_id]),
        }))
    end

    return (util.render([[
        int ${name}(lua_State *L)
        {
            luaL_checkversion(L);

            /**/

            lua_newuserdatauv(L, 0, $n_upvalues);
            int globals = lua_gettop(L);

            /**/

            lua_createtable(L, $n_closures, 0);
            int closures = lua_gettop(L);

            /**/

            lua_newtable(L);
            int export_table = lua_gettop(L);

            /**/
            /* Closures */
            /**/

            ${init_closures}

            /**/
            /* Global values */
            /**/

            ${init_upvalues}

            /**/
            /* Exports */
            /**/

            ${init_exports}

            /**/

            lua_pushvalue(L, export_table);
            return 1;
        }
    ]], {
        name = "luaopen_" .. self.modname,
        n_closures = C.integer(#self.closures),
        n_upvalues = C.integer(#self.upvalues),
        init_closures = table.concat(init_closures, "\n"),
        init_upvalues = table.concat(init_upvalues, "\n"),
        init_exports  = table.concat(init_exports, "\n"),
    }))
end

return coder

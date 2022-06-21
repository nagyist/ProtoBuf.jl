const JULIA_RESERVED_KEYWORDS = Set{String}([
    "baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end",
    "export", "false", "finally", "for", "function", "global", "if", "import", "let", "local",
    "macro", "module", "quote", "return", "struct", "true", "try", "using", "while",
    "abstract", "ccall", "typealias", "type", "bitstype", "importall", "immutable", "Type", "Enum",
    "Any", "DataType", "Base", "Core", "InteractiveUtils", "Set", "Method", "include", "eval", "ans",
    # TODO: add all subtypes(Any) from a fresh julia session?
    "PB", "OneOf", "Nothing", "Vector", "zero", "isempty", "isnothing", "Ref",
])

struct Context
    proto_file::ProtoFile
    imports::Set{String}
    file_map::Dict{String,ResolvedProtoFile}
    _curr_cyclic_defs::Set{String}
end

struct ParamMetadata
    param::String
    bound::String
end

function try_strip_namespace(name::AbstractString, imports::Set{String})
    for _import in imports
        if startswith(name, "$(_import).")
            return @view name[nextind(name, length(_import), 2):end]
        end
    end
    return name
end

function safename(name::AbstractString, imports::Set{String})
    for _import in imports
        if startswith(name, "$(_import).")
            namespaced_name = @view name[nextind(name, length(_import), 2):end]
            return string(proto_module_name(_import), '.', safename(namespaced_name))
        end
    end
    return safename(name)
end

function safename(name::AbstractString)
    # TODO: handle namespaced definitions (pkg_name.MessageType)
    dot_pos = findfirst(==('.'), name)
    if name in JULIA_RESERVED_KEYWORDS
        return string("var\"#", name, '"')
    elseif isnothing(dot_pos) && !('#' in name)
        return name
    elseif dot_pos == 1
        return string("@__MODULE__.", safename(@view name[2:end]))
    else
        return string("var\"", name, '"')
    end
end

function abstract_type_name(name::AbstractString)
    return string("var\"##Abstract", name, '"')
end

function _is_message(t::ReferencedType, ctx)
    isa(get(ctx.proto_file.definitions, t.name, nothing), MessageType) && return true
    lookup_name = try_strip_namespace(t.name, ctx.imports)
    for path in import_paths(ctx.proto_file)
        defs = ctx.file_map[path].proto_file.definitions
        isa(get(defs, lookup_name, nothing), MessageType) && return true
    end
    return false
end

function _is_enum(t::ReferencedType, ctx)
    isa(get(ctx.proto_file.definitions, t.name, nothing), EnumType) && return true
    lookup_name = try_strip_namespace(t.name, ctx.imports)
    for path in import_paths(ctx.proto_file)
        defs = ctx.file_map[path].proto_file.definitions
        isa(get(defs, lookup_name, nothing), EnumType) && return true
    end
    return false
end

jl_fieldname(f::AbstractProtoFieldType) = safename(f.name)
jl_fieldname(f::GroupType) = safename(f.field_name)

function jl_typename(f::AbstractProtoFieldType, ctx)
    type_name = jl_typename(f.type, ctx)
    if _is_repeated_field(f)
        return string("Vector{", type_name, "}")
    end
    return type_name
end

_decoding_val_type(t::AbstractProtoType) = ""
_decoding_val_type(t::AbstractProtoFixedType) = ":fixed"
_decoding_val_type(t::T) where {T<:Union{SInt32Type,SInt64Type}} = ":zigzag"

jl_typename(::DoubleType, ctx)   = "Float64"
jl_typename(::FloatType, ctx)    = "Float32"
jl_typename(::Int32Type, ctx)    = "Int32"
jl_typename(::Int64Type, ctx)    = "Int64"
jl_typename(::UInt32Type, ctx)   = "UInt32"
jl_typename(::UInt64Type, ctx)   = "UInt64"
jl_typename(::SInt32Type, ctx)   = "Int32"
jl_typename(::SInt64Type, ctx)   = "Int64"
jl_typename(::Fixed32Type, ctx)  = "UInt32"
jl_typename(::Fixed64Type, ctx)  = "UInt64"
jl_typename(::SFixed32Type, ctx) = "Int32"
jl_typename(::SFixed64Type, ctx) = "Int64"
jl_typename(::BoolType, ctx)     = "Bool"
jl_typename(::StringType, ctx)   = "String"
jl_typename(::BytesType, ctx)    = "Vector{UInt8}"
jl_typename(t::MessageType, ctx) = safename(t.name, ctx.imports)
function jl_typename(t::MapType, ctx)
    key_type = jl_typename(t.keytype, ctx)
    val_type = jl_typename(t.valuetype, ctx)
    return string("Dict{", key_type, ',', val_type,"}")
end
function jl_typename(t::ReferencedType, ctx)
    name = safename(t.name, ctx.imports)
    # This is where EnumX.jl bites us -- we need to search through all defitnition (including imported)
    # to make sure a ReferencedType is an Enum, in which case we need to add a `.T` suffix.
    isa(get(ctx.proto_file.definitions, t.name, nothing), EnumType) && return string(name, ".T")
    lookup_name = try_strip_namespace(t.name, ctx.imports)
    for path in import_paths(ctx.proto_file)
        defs = ctx.file_map[path].proto_file.definitions
        isa(get(defs, lookup_name, nothing), EnumType) && return string(name, ".T")
    end
    return name
end
# NOTE: If there is a self-reference to the parent type, we might get
#       a Union{..., Union{Nothing,parentType}, ...}. This is probably ok?
function jl_typename(t::OneOfType, ctx)
    return string("OneOf{", _jl_inner_typename(t, ctx), "}")
end

function _jl_inner_typename(t::OneOfType, ctx)
    union_types = unique!([jl_typename(f.type, ctx) for f in t.fields])
    return length(union_types) == 1 ? only(union_types) : string("Union{", join(union_types, ','), '}')
end

_is_repeated_field(f::AbstractProtoFieldType) = f.label == Parsers.REPEATED
_is_repeated_field(::OneOfType) = false

function jl_default_value(field::FieldType, ctx)
    if _is_repeated_field(field)
        return "PB.BufferedVector{$(jl_typename(field.type, ctx))}()"
    else
        return jl_type_default(field, ctx)
    end
end
jl_type_default(f::FieldType{StringType}, ctx) = get(f.options, "default", "\"\"")
jl_type_default(f::FieldType{BoolType}, ctx)   = get(f.options, "default", "false")
function jl_type_default(f::FieldType{<:AbstractProtoFloatType}, ctx)
    type_name = jl_typename(f, ctx)
    default = get(f.options, "default", nothing)
    if default === nothing
        return "zero($(jl_typename(f.type, ctx)))"
    end
    ldefault = lowercase(default)
    if ldefault == "inf"
        default = "Inf"
    elseif ldefault == "-inf"
        default = "-Inf"
    elseif ldefault == "nan"
        default = "NaN"
    elseif ldefault == "-nan"
        default = "-NaN"
    elseif ldefault == "+inf"
        default = "+Inf"
    elseif ldefault == "+nan"
        default = "+NaN"
    end
    return string(type_name, '(', default, ')')
end
_jl_parse_default_int(::Union{Int32Type,SInt32Type,SFixed32Type}, s::String) = parse(Int32, s)
_jl_parse_default_int(::Union{Int64Type,SInt64Type,SFixed64Type}, s::String) = parse(Int64, s)
_jl_parse_default_int(::Union{UInt32Type,Fixed32Type}, s::String) = parse(UInt32, s)
_jl_parse_default_int(::Union{UInt64Type,Fixed64Type}, s::String) = parse(UInt64, s)
function jl_type_default(f::FieldType{<:AbstractProtoNumericType}, ctx)
    type_name = jl_typename(f, ctx)
    default = get(f.options, "default", nothing)
    if default === nothing
        return "zero($(jl_typename(f.type, ctx)))"
    end
    return string(type_name, '(', repr(_jl_parse_default_int(f.type, default)), ')')
end
function jl_type_default(f::FieldType{BytesType}, ctx)
    out = get(f.options, "default", nothing)
    return isnothing(out) ? "UInt8[]" : "b$(out)"
end
function jl_type_default(f::FieldType{ReferencedType}, ctx)
    if _is_enum(f.type, ctx)
        default = get(f.options, "default", "0")
        if default == "0"
            return "$(jl_typename(f.type, ctx))(0)"
        else
            return "$(jl_typename(f.type, ctx)[1:end-2]).$(default)"
        end
    else # message, AFAIK services shouldn't be referenced
        return "Ref{$(jl_typename(f.type, ctx))}()"
    end
end
# end
function jl_type_default(f::FieldType{MapType}, ctx)
    return "Dict{$(jl_typename(f.type.keytype, ctx)),$(jl_typename(f.type.valuetype, ctx))}()"
end
function jl_default_value(::OneOfType, ctx)
    return "nothing"
end
function jl_default_value(f::GroupType, ctx)
    if _is_repeated_field(f)
        return "PB.BufferedVector{$(jl_typename(f.type, ctx))}()"
    else
        return "Ref{$(jl_typename(f.type, ctx))}()"
    end
end

jl_type_decode_expr(f::FieldType{<:AbstractProtoType}, ctx) = "$(jl_fieldname(f)) = PB.decode(d, $(jl_typename(f.type, ctx)))"
jl_type_decode_expr(f::FieldType{SFixed32Type}, ctx) = "$(jl_fieldname(f)) = PB.decode(d, Int32, Val{:fixed})"
jl_type_decode_expr(f::FieldType{SFixed64Type}, ctx) = "$(jl_fieldname(f)) = PB.decode(d, Int64, Val{:fixed})"
jl_type_decode_expr(f::FieldType{Fixed32Type}, ctx)  = "$(jl_fieldname(f)) = PB.decode(d, UInt32, Val{:fixed})"
jl_type_decode_expr(f::FieldType{Fixed64Type}, ctx)  = "$(jl_fieldname(f)) = PB.decode(d, UInt64, Val{:fixed})"
jl_type_decode_expr(f::FieldType{SInt32Type}, ctx)   = "$(jl_fieldname(f)) = PB.decode(d, Int32, Val{:zigzag})"
jl_type_decode_expr(f::FieldType{SInt64Type}, ctx)   = "$(jl_fieldname(f)) = PB.decode(d, Int64, Val{:zigzag})"
function jl_type_decode_expr(f::FieldType{MapType}, ctx)
    K = _decoding_val_type(f.type.keytype)
    V = _decoding_val_type(f.type.valuetype)
    isempty(V) && isempty(K) && return "PB.decode!(d, $(jl_fieldname(f)))"
    !isempty(V) && isempty(K) && return "PB.decode!(d, $(jl_fieldname(f)), Val{Tuple{Nothing,$(V)}})"
    isempty(V) && !isempty(K) && return "PB.decode!(d, $(jl_fieldname(f)), Val{Tuple{$(K),Nothing}})"
    return "PB.decode!(d, $(jl_fieldname(f)), Val{Tuple{$(K),$(V)}})"
end

function jl_type_decode_repeated_expr(f::FieldType{T}, ctx) where {T<:Union{StringType,BytesType}}
    return "PB.decode!(d, $(jl_fieldname(f)))"
end
function jl_type_decode_repeated_expr(f::FieldType{T}, ctx) where {T<:AbstractProtoNumericType}
    return "PB.decode!(d, wire_type, $(jl_fieldname(f)))"
end
function jl_type_decode_repeated_expr(f::FieldType{T}, ctx) where {T<:AbstractProtoFixedType}
    return "PB.decode!(d, wire_type, $(jl_fieldname(f)), Var{:fixed})"
end
function jl_type_decode_repeated_expr(f::FieldType{T}, ctx) where {T<:Union{SInt32Type,SInt64Type}}
    return "PB.decode!(d, wire_type, $(jl_fieldname(f)), Var{:zigzag})"
end
function jl_type_decode_repeated_expr(f::FieldType{ReferencedType}, ctx)
    _is_message(f.type, ctx) && return "$(jl_fieldname(f)) = PB.decode!(d, $(jl_fieldname(f)))"
    return "PB.decode!(d, wire_type, $(jl_fieldname(f)))"
end
function jl_type_decode_expr(f::FieldType{ReferencedType}, ctx)
    _is_message(f.type, ctx) && return "$(jl_fieldname(f)) = PB.decode!(d, $(jl_fieldname(f)))"
    return "$(jl_fieldname(f)) = PB.decode(d, $(jl_typename(f.type, ctx)))"
end

function field_decode_expr(io, f::FieldType, i, ctx)
    if _is_repeated_field(f)
        decode_expr = jl_type_decode_repeated_expr(f, ctx)
    else
        decode_expr = jl_type_decode_expr(f, ctx)
    end
    println(io, "    " ^ 2, i == 1 ? "if " : "elseif ", "field_number == ", f.number)
    println(io, "    " ^ 3, decode_expr)
    return nothing
end

jl_type_oneof_decode_expr(f::FieldType, ctx) = "OneOf(:$(jl_fieldname(f)), PB.decode(d, $(jl_typename(f.type, ctx))))"
jl_type_oneof_decode_expr(f::GroupType, ctx) = "OneOf(:$(jl_fieldname(f)), PB.decode(d, $(jl_typename(f.type, ctx))))"
jl_type_oneof_decode_expr(f::FieldType{SFixed32Type}, ctx) = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int32, Val(:fixed)))"
jl_type_oneof_decode_expr(f::FieldType{SFixed64Type}, ctx) = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int64, Val(:fixed)))"
jl_type_oneof_decode_expr(f::FieldType{Fixed32Type}, ctx)  = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int32, Val(:fixed)))"
jl_type_oneof_decode_expr(f::FieldType{Fixed64Type}, ctx)  = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int64, Val(:fixed)))"
jl_type_oneof_decode_expr(f::FieldType{SInt32Type}, ctx)   = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int32, Val(:zigzag)))"
jl_type_oneof_decode_expr(f::FieldType{SInt64Type}, ctx)   = "OneOf(:$(jl_fieldname(f)), PB.decode(d, Int64, Val(:zigzag)))"
# function jl_type_decode_expr(f, t::ReferencedType, ctx)
#     _is_message(t, ctx) && return "OneOf(:$(jl_fieldname(f)),PB.decode_message(d, $(jl_fieldname(f))))"
#     return "OneOf(:$(jl_fieldname(f)), PB.decode(d, $(jl_typename(t, ctx))))"
# end
function field_decode_expr(io, field::OneOfType, i, ctx)
    field_name = jl_fieldname(field)
    for (j, case) in enumerate(field.fields)
        j += i
        println(io, "    " ^ 2, j == 2 ? "if " : "elseif ", "field_number == ", case.number)
        println(io, "    " ^ 3, field_name, " = ", jl_type_oneof_decode_expr(case, ctx))
    end
    return nothing
end

function field_decode_expr(io, field::GroupType, i, ctx)
    field_name = jl_fieldname(field)
    println(io, "    " ^ 2, i == 1 ? "if " : "elseif ", "field_number == ", field.number)
    println(io, "    " ^ 3, field_name, " = PB.decode(d, ", field_name, ")")
    return nothing
end

jl_fieldname_deref(f, ctx) = _is_repeated_field(f) ? "$(jl_fieldname(f))[]" : jl_fieldname(f)
function jl_fieldname_deref(f::FieldType{ReferencedType}, ctx)
    should_deref = _is_repeated_field(f) | _is_message(f.type, ctx)
    return should_deref ? "$(jl_fieldname(f))[]" : jl_fieldname(f)
end

function generate_decode_method(io, t::MessageType, ctx)
    println(io, "function PB.decode(d::PB.ProtoDecoder, ::Type{$(safename(t.name))})")
    # defaults
    for field in t.fields
        println(io, "    ", jl_fieldname(field), " = ", jl_default_value(field, ctx))
    end
    println(io, "    while !PB.message_done(d)")
    println(io, "        field_number, wire_type = PB.decode_tag(d)")
    for (i, field) in enumerate(t.fields)
        field_decode_expr(io, field, i, ctx)
    end
    println(io, "        else")
    println(io, "            PB.skip(d, wire_type)")
    println(io, "        end")
    println(io, "        PB.try_eat_end_group(d, wire_type)")
    println(io, "    end")
    print(io, "    return ", jl_typename(t, ctx), "(")
    print(io, join(map(f->jl_fieldname_deref(f, ctx), t.fields), ", "))
    println(io, ")")
    println(io, "end")
end

function encode_condition(f::FieldType, ctx)
    if _is_repeated_field(f)
        return "!isempty(x.$(jl_fieldname(f)))"
    else
        return _encode_condition(f, ctx)
    end
end
_encode_condition(f::FieldType, ctx) = "x.$(jl_fieldname(f)) != $(jl_default_value(f, ctx))"
_encode_condition(f::OneOfType, ctx) = "!isnothing(x.$(jl_fieldname(f)))"
function _encode_condition(f::FieldType{ReferencedType}, ctx)
    if _is_message(f.type, ctx)
        return "!isnothing(x.$(jl_fieldname(f)))"
    else
        return "x.$(jl_fieldname(f)) != $(jl_default_value(f, ctx))"
    end
end

field_encode_expr(f::GroupType, ctx) = "PB.encode(io, $(f.number), x.$(jl_fieldname(f)))"
function field_encode_expr(f::FieldType, ctx)
    if _is_repeated_field(f)
        encoding_val_type = _decoding_val_type(f.type)
        !isempty(encoding_val_type) && (encoding_val_type = ", $encoding_val_type")
        # TODO: do we want to allow unpacked representation? Docs say that parsers must always handle both cases
        # and since packed is strictly more efficient, currently we don't allow that.
        # is_packed = parse(Bool, get(f.options, "packed", "false"))
        # if is_packed
            return "PB.encode(io, $(f.number), x.$(jl_fieldname(f))$(encoding_val_type))"
        # else
        #     return """
        #     for el in x.$(jl_fieldname(f))
        #                 PB.encode(io, $(f.number), el$(encoding_val_type))
        #             end"""
        # end
    else
        return _field_encode_expr(f, ctx)
    end
end

_field_encode_expr(f::FieldType, ctx) = "PB.encode(io, $(f.number), x.$(jl_fieldname(f)))"
_field_encode_expr(f::GroupType, ctx) = "PB.encode(io, $(f.number), x.$(jl_fieldname(f)))"
_field_encode_expr(f::FieldType{<:AbstractProtoFixedType}, ctx) = "PB.encode(io, $(f.number), x.$(jl_fieldname(f)), Val{:fixed})"
_field_encode_expr(f::FieldType{<:Union{SInt32Type,SInt64Type}}, ctx) = "PB.encode(io, $(f.number), x.$(jl_fieldname(f)), Val{:zigzag})"
function _field_encode_expr(f::FieldType{<:MapType}, ctx)
    K = _decoding_val_type(f.type.keytype)
    V = _decoding_val_type(f.type.valuetype)
    isempty(V) && isempty(K) && return "PB.encode(io, $(f.number), $(jl_fieldname(f)))"
    !isempty(V) && isempty(K) && return "PB.encode(io, $(f.number), $(jl_fieldname(f)), Val{Tuple{Nothing,$(V)}})"
    isempty(V) && !isempty(K) && return "PB.encode(io, $(f.number), $(jl_fieldname(f)), Val{Tuple{$(K),Nothing}})"
    return "PB.encode(io, $(f.number), $(jl_fieldname(f)), Val{Tuple{$(K),$(V)}})"
end

function print_field_encode_expr(io, f::FieldType, ctx)
    println(io, "    ", encode_condition(f, ctx), " && ", field_encode_expr(f, ctx))
end

function print_field_encode_expr(io, f::GroupType, ctx)
    println(io, "    isnothing!($(jl_fieldname(f))) && ", field_encode_expr(f, ctx))
end

function print_field_encode_expr(io, fs::OneOfType, ctx)
    println(io, "    if isnothing(x.$(safename(fs.name)));")
    for f in fs.fields
        println(io, "    elseif ", "x.$(safename(fs.name)).name == :", jl_fieldname(f))
        println(io, "    " ^ 2, field_encode_expr(f, ctx))
    end
    println(io, "    end")
end

function generate_encode_method(io, t::MessageType, ctx)
    println(io, "function PB.encode(io::IO, x::$(safename(t.name)))")
    println(io, "    initpos = position(io)")
    for field in t.fields
        print_field_encode_expr(io, field, ctx)
    end
    println(io, "    return position(io) - initpos", )
    println(io, "end")
end

function generate_encode_method(io, t::GroupType, ctx)
    generate_encode_method(io, t.type, ctx)
end

function generate_struct_field(io, field, struct_name, ctx, type_params)
    field_name = jl_fieldname(field)
    type_name = jl_typename(field, ctx)
    # When a field type is self-referential, we'll use Nothing to signal
    # the bottom of the recursion. Note that we don't have to do this
    # for repeated (`Vector{...}`) types; at this point `type_name`
    # is already a vector if the field was repeated.
    if struct_name == type_name
        type_name = string("Union{Nothing,", type_name,"}")
    else
        type_param = get(type_params, field.name, nothing)
        if !isnothing(type_param)
            type_name = string("Union{Nothing,", type_param.param,"}")
        end
    end
    println(io, "    ", field_name, "::", type_name)
end

function generate_struct_field(io, field::OneOfType, struct_name, ctx, type_params)
    field_name = jl_fieldname(field)
    @info field_name
    # When a field type is self-referential, we'll use Nothing to signal
    # the bottom of the recursion. Note that we don't have to do this
    # for repeated (`Vector{...}`) types; at this point `type_name`
    # is already a vector if the field was repeated.
    type_param = get(type_params, field.name, nothing)
    if !isnothing(type_param)
        type_name = string("Union{Nothing,OneOf{", type_param.param,"}}")
    else
        type_name = string("Union{Nothing,",jl_typename(field, ctx),'}')
    end
    println(io, "    ", field_name, "::", type_name)
end

codegen(t::AbstractProtoType, ctx::Context) = codegen(stdin, t, ctx::Context)

_needs_type_params(f::FieldType{ReferencedType}, ctx) = f.type.name in ctx._curr_cyclic_defs
_needs_type_params(f::FieldType, ctx) = false
_needs_type_params(f::OneOfType, ctx) = true
_needs_type_params(f::GroupType, ctx) = f.name in ctx._curr_cyclic_defs

_get_type_bound(f::FieldType{ReferencedType}, ctx) = abstract_type_name(f.type.name)
_get_type_bound(f::OneOfType, ctx) = _jl_inner_typename(f, ctx) # TODO: handle mutually recursive types in OneOf!
_get_type_bound(f::GroupType, ctx) = abstract_type_name(f.name)

function _maybe_subtype(name)
    isempty(name) && return ""
    return string(" <: ", abstract_type_name(name))
end

function get_type_params(t::MessageType, ctx)
    out = [field.name => _get_type_bound(field, ctx) for field in t.fields if _needs_type_params(field, ctx)]
    type_params = Dict(k => ParamMetadata(string("T", i), v) for (i, (k, v)) in enumerate(out))
    return type_params
end

function get_type_param_string(type_params)
    isempty(type_params) && return ""
    return string('{', join(Iterators.map(x->string(x.param, "<:", x.bound), values(type_params)), ','), '}')
end

function codegen(io, t::MessageType, ctx::Context)
    struct_name = safename(t.name)
    # After we're done with this struct, all the subsequent definitions can use it
    # so we pop it from the list of cyclic definitions.
    abstract_base_name = pop!(ctx._curr_cyclic_defs, t.name, "")
    type_params = get_type_params(t, ctx)
    params_string = get_type_param_string(type_params)

    print(io, "struct ", struct_name, length(t.fields) > 0 ? params_string : ' ', _maybe_subtype(abstract_base_name))
    length(t.fields) > 0 && println(io)
    for field in t.fields
        generate_struct_field(io, field, struct_name, ctx, type_params)
    end
    println(io, "end")
    if !isempty(t.fields)
        println(io)
        generate_decode_method(io, t, ctx)
        println(io)
        generate_encode_method(io, t, ctx)
    end
end

codegen(io, t::GroupType, ctx::Context) = codegen(io, t.type, ctx)

function codegen(io, t::EnumType, ::Context)
    name = safename(t.name)
    println(io, "@enumx ", name, join(" $k=$n" for (k, n) in zip(keys(t.elements), t.elements)))
end

function codegen(io, t::ServiceType, ::Context)
    println(io, "# TODO: SERVICE")
    println(io, "#    ", safename(t.name))
end

function translate(path::String, rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile})
    open(path, "w") do io
        translate(io, rp, file_map)
    end
end

translate(rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile}) = translate(stdin, rp, file_map)
function translate(io, rp::ResolvedProtoFile, file_map::Dict{String,ResolvedProtoFile})
    p = rp.proto_file
    imports = Set{String}(Iterators.map(i->namespace(file_map[i]), import_paths(p)))
    println(io, "# Autogenerated using ProtocolBuffers.jl v$(PACKAGE_VERSION) on $(Dates.now())")
    println(io, "# original file: ", p.filepath," (proto", p.preamble.isproto3 ? '3' : '2', " syntax)")
    println(io)

    ctx = Context(p, imports, file_map, copy(p.cyclic_definitions))
    if !is_namespaced(p)
        # if current file is not namespaced, it will not live in a module
        # and will need to import its dependencies directly.
        for path in import_paths(p)
            dependency = file_map[path]
            if !is_namespaced(dependency)
                # if the dependency is also not namespaced, we can just include it
                println(io, "include(", repr(proto_script_name(dependency)), ")")
            else
                # otherwise we need to import it trough a module
                println(io, "include(", repr(proto_module_name(dependency)), ")")
                println(io, "using ", proto_module_name(dependency))
            end
        end
    end # Otherwise all includes will happen in the enclosing module
    println(io, "import ProtocolBuffers as PB")
    println(io, "using ProtocolBuffers: OneOf")
    println(io, "using EnumX: @enumx")
    if is_namespaced(p)
        println(io)
        println(io, "export ", join(Iterators.map(x->safename(x, imports), keys(p.definitions)), ", "))
    end
    !isempty(p.cyclic_definitions) && println(io, "\n# Abstract types to help resolve mutually recursive definitions")
    for name in p.cyclic_definitions
        println(io, "abstract type ", abstract_type_name(name), " end")
    end
    println(io)
    for def_name in p.sorted_definitions
        println(io)
        codegen(io, p.definitions[def_name], ctx)
    end
end
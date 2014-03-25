# These are some functions to allow static type-checking of Julia programs

module TypeCheck
export check_return_types, check_loop_types, check_method_calls,
  methodswithdescendants

function Base.code_typed(f::Function)
  Expr[code_typed(m) for m in f.env]
end

function Base.code_typed(m::Method)
 linfo = m.func.code
 (tree,ty) = Base.typeinf(linfo,m.sig,())
 if !isa(tree,Expr)
     ccall(:jl_uncompress_ast, Any, (Any,Any), linfo, tree)
  else
    tree
  end
end

function _whos(e::Expr)
  vars = sort(e.args[2][2];by=x->x[1])
  [println("\t",x[1],"\t",x[2]) for x in vars]
end

function Base.whos(f,args...)
  for e in code_typed(f,args...)
    println(signature(e))
    _whos(e)                                
    println("")
  end
end

returntype(e::Expr) =  e.args[3].typ
body(e::Expr) = e.args[3].args
returns(e::Expr) = filter(x-> typeof(x) == Expr && x.head==:return,body(e))
call_info(call::Expr) = (call.args[1], AType[expr_type(e) for e in call.args[2:end]])

function signature(e::Expr)
  r = returntype(e) 
 "($(string_of_argtypes(argtypes(e))))::$(r)"
end
  
function extract_calls_from_returns(e::Expr)
  rs = returns(e)
  rs_with_calls = filter(x->typeof(x.args[1]) == Expr && x.args[1].head == :call,rs)
  Expr[expr.args[1] for expr in rs_with_calls]
end

AType = Union(Type,TypeVar)

# for a function, get the types of each of the arguments in the signature
function argtypes(e::Expr)
  argnames = Symbol[typeof(x) == Symbol ? x : x.args[1] for x in e.args[1]]
  argtuples = filter(x->x[1] in argnames, e.args[2][2]) #only arguments, no local vars
  AType[t[2] for t in argtuples]
end

function string_of_argtypes(arr::Vector{AType})
  join([string(a) for a in arr],",")
end

is_top(e) = Base.is_expr(e,:call) && typeof(e.args[1]) == TopNode
function returntype(e::Expr,context::Expr) #must be :call,:new,:call1
  if Base.is_expr(e,:new); return e.typ; end
  if Base.is_expr(e,:call1) && isa(e.args[1], TopNode); return e.typ; end
  if !Base.is_expr(e,:call); error("Expected :call Expr"); end

  if is_top(e)
    return e.typ
  end

  callee = e.args[1]
  if is_top(callee)
    return returntype(callee,context)
  elseif isa(callee,SymbolNode) # only seen (func::F), so non-generic function
    return Any
  elseif is(callee,Symbol)
    if e.typ != Any || any([isa(x,LambdaStaticData) for x in e.args[2:end]])
      return e.typ
    end

    if isdefined(Base,callee)
      f = eval(Base,callee)
      if !isa(f,Function) || !isgeneric(f)
        return e.typ
      end
      fargtypes = tuple([argtype(ea,context) for ea in e.args[2:end]])
      return Union([returntype(ef) for ef in code_typed(f,fargtypes)]...)
    else
      return @show e.typ
    end
  end

  return e.typ
end

function argtype(e::Expr,context::Expr)
 if Base.is_expr(e,:call) || Base.is_expr(e,:new) || Base.is_expr(e,:call1)
   return returntype(e,context)
 end

 @show e
 return Any
end
function argtype(s::Symbol,e::Expr)
  vartypes = [x[1] => x[2] for x in e.args[2][2]]
  s in vartypes ? (vartypes[@show s]) : Any
end
argtype(s::SymbolNode,e::Expr) = s.typ
argtype(t::TopNode,e::Expr) = Any
argtype(l::LambdaStaticData,e::Expr) = Function
argtype(q::QuoteNode,e::Expr) = argtype(q.value,e)

#TODO: how to deal with immediate values
argtype(n::Number,e::Expr) = typeof(n)
argtype(c::Char,e::Expr) = typeof(c)
argtype(s::String,e::Expr) = typeof(s)
argtype(i,e::Expr) = typeof(i)

Base.start(t::DataType) = [t]
function Base.next(t::DataType,arr::Vector{DataType})
  c = pop!(arr)
  append!(arr,[x for x in subtypes(c)])
  (c,arr)
end
Base.done(t::DataType,arr::Vector{DataType}) = length(arr) == 0

function methodswithdescendants(t::DataType;onlyleaves::Bool=false,lim::Int=10)
  d = Dict{Symbol,Int}()
  count = 0
  for s in t
    if !onlyleaves || (onlyleaves && isleaftype(s))
      count += 1
      fs = Set{Symbol}()
      for m in methodswith(s)
        push!(fs,m.func.code.name)
      end
      for sym in fs
        d[sym] = get(d,sym,0) + 1
      end
    end
  end
  l = [(k,v/count) for (k,v) in d]
  sort!(l,by=(x->x[2]),rev=true)
  l[1:min(lim,end)]
end

# check all the generic functions in a module
function check_all_module(m::Module;test=check_return_types,kwargs...)
  score = 0
  for n in names(m)
    f = eval(m,n)
    if isgeneric(f) && typeof(f) == Function
      fm = test(f;mod=m,kwargs...)
      score += length(fm.methods)
      display(fm)
    end
  end
  println("The total number of failed methods in $m is $score")
end

type MethodSignature
  typs::Vector{AType}
  returntype::Union(Type,TypeVar) # v0.2 has TypeVars as returntypes; v0.3 does not
end
MethodSignature(e::Expr) = MethodSignature(argtypes(e),returntype(e))
Base.writemime(io, ::MIME"text/plain", x::MethodSignature) = println(io,"(",string_of_argtypes(x.typs),")::",x.returntype)

## Checking that return values are base only on input *types*, not values.

type FunctionSignature
  methods::Vector{MethodSignature}
  name::Symbol
end

function Base.writemime(io, ::MIME"text/plain", x::FunctionSignature)
  for m in x.methods
    print(io,string(x.name))
    display(m)
  end
end

check_return_types(m::Module;kwargs...) = check_all_module(m;test=check_return_types,kwargs...)

function check_return_types(f::Function;kwargs...)
  results = MethodSignature[]
  for e in code_typed(f)
    (ms,b) = check_return_type(e;kwargs...)
    if b push!(results,ms) end
  end
  FunctionSignature(results,f.env.name)
end

function check_return_type(e::Expr;kwargs...)
  (typ,b) = isreturnbasedonvalues(e;kwargs...)
  (MethodSignature(argtypes(e),typ),b)
end
 
# Determine whether this method's return type might change based on input values rather than input types
function isreturnbasedonvalues(e::Expr;mod=Base)
  rt = returntype(e)
  ts = argtypes(e)
  if isleaftype(rt) || rt == None return (rt,false) end

  for t in ts
    if !isleaftype(t)
      return (rt,false)
    end
  end

  cs = [returntype(c,e) for c in extract_calls_from_returns(e)]
  for c in cs
    if rt == c
       return (rt,false)
    end
  end

  return (rt,true) # return is not concrete type; all args are concrete types
end

## Checking that variables in loops have concrete types
  
type LoopResult
  msig::MethodSignature
  lines::Vector{(Symbol,Type)} #TODO should this be a specialized type? SymbolNode?
  LoopResult(ms::MethodSignature,ls::Vector{(Symbol,Type)}) = new(ms,unique(ls))
end

function Base.writemime(io, ::MIME"text/plain", x::LoopResult)
  display(x.msig)
  for (s,t) in x.lines
    println(io,"\t",string(s),"::",string(t))
  end
end

type LoopResults
  name::Symbol
  methods::Vector{LoopResult}
end

function Base.writemime(io, ::MIME"text/plain", x::LoopResults)
  for lr in x.methods
    print(io,string(x.name))
    display(lr)
  end
end

check_loop_types(m::Module) = check_all_module(m;test=check_loop_types)

function check_loop_types(f::Function;kwargs...)
  lrs = LoopResult[]
  for e in code_typed(f)
    lr = check_loop_types(e)
    if length(lr.lines) > 0 push!(lrs,lr) end
  end
  LoopResults(f.env.name,lrs)
end

check_loop_types(e::Expr;kwargs...) = loosetypes(e,loopcontents(e))
 
# This is a function for trying to detect loops in a method of a generic function
# Returns lines that are inside one or more loops
function loopcontents(e)
  b = body(e)
  loops = Int[]
  nesting = 0
  lines = {}
  for i in 1:length(b)
    if typeof(b[i]) == LabelNode
      l = b[i].label
      jumpback = findnext(
        x-> (typeof(x) == GotoNode && x.label == l) || (Base.is_expr(x,:gotoifnot) && x.args[end] == l),
        b, i)
      if jumpback != 0
        push!(loops,jumpback)
        nesting += 1
      end
    end
    if nesting > 0
      push!(lines,(i,b[i]))
    end

    if typeof(b[i]) == GotoNode && in(i,loops)
      splice!(loops,findfirst(loops,i))
      nesting -= 1
    end
  end
  lines
end

# Looks for variables with non-leaf types
function loosetypes(method::Expr,lr::Vector)
  lines = (Symbol,Type)[]
  for (i,e) in lr
    if typeof(e) == Expr
      es = copy(e.args)
      while !isempty(es)
        e1 = pop!(es)
        if typeof(e1) == Expr
          append!(es,e1.args)
        elseif typeof(e1) == SymbolNode && !isleaftype(e1.typ) && typeof(e1.typ) == UnionType
          push!(lines,(e1.name,e1.typ))
        end 
      end                          
    end
  end
  return LoopResult(MethodSignature(method),lines)
end

## Check method calls

type CallSignature
  name::Symbol
  argtypes::Vector{AType}
end
Base.writemime(io, ::MIME"text/plain", x::CallSignature) = println(io,string(x.name),"(",string_of_argtypes(x.argtypes),")")

type MethodCalls
  m::MethodSignature
  calls::Vector{CallSignature}
end

function Base.writemime(io, ::MIME"text/plain", x::MethodCalls)
  display(x.m)
  for c in x.calls
    print(io,"\t")
    display(c)
  end
end

type FunctionCalls
  name::Symbol
  methods::Vector{MethodCalls}
end

function Base.writemime(io, ::MIME"text/plain", x::FunctionCalls)
  for mc in x.methods
    print(io,string(x.name))
    display(mc)
  end
end

check_method_calls(m::Module) = check_all_module(m;test=check_method_calls)

function check_method_calls(f::Function;kwargs...)
  calls = MethodCalls[] 
  for m in f.env
    e = code_typed(m)
    mc = check_method_calls(e,m;kwargs...)
    if !isempty(mc.calls)
      push!(calls, mc)
    end
  end
  FunctionCalls(f.env.name,calls)
end

function check_method_calls(e::Expr,m::Method;kwargs...)
  if Base.arg_decl_parts(m)[3] == symbol("deprecated.jl")
    CallSignature[]
  end
  no_method_errors(e,method_calls(e);kwargs...)
end

# Find any methods that match the given CallSignature
function hasmatches(mod::Module,cs::CallSignature)
  if isdefined(mod,cs.name)
    f = eval(mod,cs.name)
    if isgeneric(f)
      opts = methods(f,tuple(cs.argtypes...))
      if isempty(opts)
        return false
      end
    end
  else
    #println("$mod.$(cs.name) is undefined")
  end
  return true
end

# Find any CallSignatures that indicate potential NoMethodErrors 
function no_method_errors(e::Expr,cs::Vector{CallSignature};mod=Base)
  output = CallSignature[]
  for callsig in cs
    if !hasmatches(mod,callsig)
      push!(output,callsig)
    end
  end
  MethodCalls(MethodSignature(e),output)
end

# Look through the body of the function for `:call`s
function method_calls(e::Expr)
  b = body(e)
  lines = CallSignature[]
  for s in b
    if typeof(s) == Expr
      if s.head == :return
        append!(b, s.args)
      elseif s.head == :call
        if typeof(s.args[1]) == Symbol
          push!(lines,CallSignature(s.args[1], [argtype(e1,e) for e1 in s.args[2:end]]))
        end
      end
    end
  end
  lines
end

end  #end module

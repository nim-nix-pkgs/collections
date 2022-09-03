## This module allow creation of interface types. Every interface type has a set of methods that can be called on it. Every object can be converted at runtime to the interface type, provided that there are procs that implement all interface methods.
##
## Example
## =======
##
## .. code-block:: nim
##   # Define interface type Duck
##   type Duck = distinct Interface
##
##   interfaceMethods Duck:
##     quack(number: int): string
##
##   # Make implementation of Duck interface
##   # Implementation objects have to inherit from RootRef.
##   type AmericanDuck = ref object of RootObj
##     name: string
##
##   proc quack(d: AmericanDuck, number: int): string =
##     return "duck " & d.name & " quacks " & $number & " times"
##
##   let myDuck: AmericanDuck = AmericanDuck(name: name)
##   let myDuckAsInterface: Duck = myDuck.asDuck # or myDuck.asInterface[Duck]
## ```

import collections/misc, collections/macrotool, collections/reflect
import macros, strutils, typetraits

type
  Interface* = object
    vtable*: ptr VTableBase
    obj*: RootRef

  VTableBase* = object {.inheritable.}
    typeName*: string

proc createVtable[T, R](ty: typedesc[T], tyFor: typedesc[R]): T =
  var tab: T
  tab = cast[T](allocShared0(sizeof(tab[]) * 100))
  tab.typeName = name(R)
  return tab

# Code generation

type
  InterfaceFunc = tuple[name: NimNode, args: NimNode, returnExpr: NimNode]

proc parseInterfaceBody(body: NimNode): seq[InterfaceFunc] {.compiletime.} =
  result = @[]
  for arg in body:
    if arg.kind == nnkCall:
      let left = arg[0]
      var funcName: NimNode
      var args: NimNode
      let ret = arg[1][0]
      if left.kind == nnkObjConstr:
        funcName = left[0]
        args = newNimNode(nnkStmtList)
        for i in 1..<left.len:
          args.add(left[i])
      elif left.kind == nnkIdent:
        funcName = left
        args = newNimNode(nnkStmtList)
      else:
        error("invalid declaration")

      funcName = newIdentNode($funcName.ident)

      result.add((funcName, args, ret).InterfaceFunc)
    elif arg.kind == nnkCommand:
      discard
    elif arg.kind == nnkCommentStmt:
      discard
    else:
      error("invalid statement in interface specification ($2: $1)" % [arg.repr, $arg.kind])

proc parseInterfaceName(nameExpr: NimNode): tuple[nameStr: string, genericParams: seq[NimNode]] =
  var genericParams: seq[NimNode] = @[]
  var nameStr: string

  if nameExpr.kind == nnkBracketExpr:
    nameStr = $nameExpr[0].ident
    for node in nameExpr: genericParams.add node
    genericParams.del(0)
  else:
    nameStr = $nameExpr.ident

  return (nameStr, genericParams)

macro interfaceMethods*(nameExpr: untyped, body: untyped): untyped =
  ## Declare method list of an interface type. (The type should be declared before in a type section as ``ExampleType = distinct Interface``).
  let (nameStr, genericParams) = parseInterfaceName(nameExpr)
  let name = newIdentNode(nameStr) # Duck

  let vtableName = newIdentNode(nameStr & "VTable") # DuckVTable
  let vtableExpr = newTypeInstance(vtableName, genericParams) # DuckVTable[T]
  let vtableDeclExpr = publicIdent(vtableName) # DuckVTable*

  let inlineImplName = newIdentNode(nameStr & "InlineImpl")
  let inlineImplDeclExpr = publicIdent(inlineImplName) # DuckInlineImpl*
  let inlineImplExpr = newTypeInstance(inlineImplName, genericParams) # DuckInlineImpl[T]

  template addGenericParams(place) =
    if place.len == 0 and genericParams.len == 0:
      place = newNimNode(nnkEmpty)
    else:
      for node in genericParams:
        place.add(newNimNode(nnkIdentDefs).add(node, newNimNode(nnkEmpty), newNimNode(nnkEmpty)))

  template shouldBeStmtList(value) =
    # wrap value in StmtList not already
    if value.kind != nnkStmtList:
      value = newNimNode(nnkStmtList).add(value)

  var vtableBody = quote do:
    type `vtableDeclExpr`[] = ptr object of VTableBase
      discard

  var inlineImplBody = quote do:
    type `inlineImplDeclExpr`[] = ref object of RootObj
      discard

  shouldBeStmtList(vtableBody)
  shouldBeStmtList(inlineImplBody)

  # add generic parameters to type decl
  addGenericParams(vtableBody[0][0][1])
  addGenericParams(inlineImplBody[0][0][1])

  let vtableInner = vtableBody[0][0][2][0][2]
  let inlineImplInner = inlineImplBody[0][0][2][0][2]
  inlineImplInner.del(0) # remove discard

  let vtableInitBody = newNimNode(nnkStmtList)
  vtableInitBody.add(newNimNode(nnkLetSection).add(
    newNimNode(nnkIdentDefs).add(newIdentNode("res"), newEmptyNode(),
                                 newCall(bindSym"createVtable", vtableExpr, newIdentNode("IMPL")))))
  let callWrappers = newNimNode(nnkStmtList)

  let functions: seq[InterfaceFunc] = parseInterfaceBody(body)

  for function in functions:
    let (funcName, args, ret) = function

    # Generate functions in vtable type
    let vtableArgs = newNimNode(nnkFormalParams).add(ret)
    vtableArgs.add(newNimNode(nnkIdentDefs).add(newIdentNode(!"self"), newIdentNode(!"RootRef"), newEmptyNode()))
    for arg in args:
      vtableArgs.add(newNimNode(nnkIdentDefs).add(arg[0], arg[1], newEmptyNode()))

    let vtableProcType = newNimNode(nnkProcTy).add(
      vtableArgs,
      newNimNode(nnkPragma).add(newIdentNode("cdecl")))
    vtableInner.add(newNimNode(nnkIdentDefs).add(funcName.copyNimTree, vtableProcType, newEmptyNode()))

    # Generate vtable body
    var vtableFunc = quote do:
      res.`funcName` = proc(self: RootRef): void {.cdecl.} =
                           mixin funcName
                           (self.IMPL).funcName() # cast[IMPL](self)
    shouldBeStmtList(vtableFunc)

    let vtableFuncBody = vtableFunc[0][1]

    let vtableFuncFormalParams = vtableFuncBody[3]
    vtableFuncFormalParams[0] = ret.copyNimTree
    for arg in args:
      vtableFuncFormalParams.add(newNimNode(nnkIdentDefs).add(arg[0], arg[1], newEmptyNode()))

    # `mixin` is removed by quote, we need to readd it
    vtableFuncBody[6][0] = newNimNode(nnkMixinStmt).add(funcName)

    let vtableFuncCall = vtableFuncBody[6][1]
    # vtableFuncCall.treeRepr.echo
    vtableFuncCall[0][1] = funcName
    #vtableFuncCall[0] = funcName
    for arg in args:
      vtableFuncCall.add(arg[0])

    vtableInitBody.add(vtableFunc)

    # Generate call wrappers
    var wrapper = quote do:
      proc `funcName`*[](self: `nameExpr`): `ret` {.inline.} =
        assert cast[Interface](self).vtable != nil
        cast[`vtableExpr`](cast[Interface](self).vtable).`funcName`(cast[Interface](self).obj)

    shouldBeStmtList(wrapper)

    for arg in args:
      wrapper[0][3].add(newNimNode(nnkIdentDefs).add(arg[0], arg[1], newEmptyNode()))

    for arg in args:
      wrapper[0][6][1].add(arg[0])

    addGenericParams(wrapper[0][2])
    callWrappers.add wrapper

    # Generate functions in inline impl type
    let inlineImplArgs = newNimNode(nnkFormalParams).add(ret)
    for arg in args:
      inlineImplArgs.add(newNimNode(nnkIdentDefs).add(arg[0], arg[1], newEmptyNode()))

    let inlineImplProcType = newNimNode(nnkProcTy).add(
      inlineImplArgs, newNimNode(nnkEmpty))
    inlineImplInner.add(newNimNode(nnkIdentDefs).add(publicIdent(funcName).copyNimTree, inlineImplProcType, newEmptyNode()))

  let converterName = newIdentNode("as" & nameStr)
  vtableInitBody.add(newNimNode(nnkReturnStmt).add(newIdentNode("res")))

  var initVtableForFunc = quote do:
    proc initVtableFor[IMPL](impl: typedesc[IMPL], iface: typedesc[`nameExpr`]): `vtableExpr` =
      `vtableInitBody`

  shouldBeStmtList(initVtableForFunc)

  addGenericParams(initVtableForFunc[0][2])

  let converterFunc = quote do:
    proc `converterName`*[IMPL](a: IMPL): `nameExpr` =
      when IMPL is not RootRef:
        static: error("interface implementation objects have to inherit from RootObj")
      if a == nil:
        raise newException(ValueError, "attempt to convert nil to interface")
      var res: Interface
      res.vtable = getVtableFor(IMPL, `nameExpr`)
      res.obj = RootRef(a)
      return `nameExpr`(res)

    proc asInterface*[IMPL](a: IMPL, t: typedesc[`nameExpr`]): `nameExpr` =
      when IMPL is not RootRef:
        static: error("interface implementation objects have to inherit from RootObj")
      if a == nil:
        raise newException(ValueError, "attempt to convert nil to interface")
      var res: Interface
      res.vtable = getVtableFor(IMPL, `nameExpr`)
      res.obj = RootRef(a)
      return `nameExpr`(res)

  addGenericParams(converterFunc[0][2])
  addGenericParams(converterFunc[1][2])

  for node in genericParams:
    let typ = newNimNode(nnkBracketExpr).add(newIdentNode("typedesc"), node)
    converterFunc[0][3].add(newNimNode(nnkIdentDefs).add(genSym(nskParam), typ, newNimNode(nnkEmpty)))

  var getVtableForFunc = quote do:
    proc getVtableFor*[IMPL](impl: typedesc[IMPL], t: typedesc[`nameExpr`]): auto {.inline.} =
      # inject is needed or `vtable` will have only one instantation for all generic variants
      var vtable {.global, inject.} = initVtableFor(IMPL, `nameExpr`)
      return vtable

  shouldBeStmtList(getVtableForFunc)
  addGenericParams(getVtableForFunc[0][2])

  result = quote do:
    `vtableBody`
    `inlineImplBody`

    `initVtableForFunc`
    `getVtableForFunc`
    `converterFunc`
    `callWrappers`

    proc isInterface*(self: `name`) = discard

    proc pprint*(self: `name`): string =
      return pprintInterface(self)

  # result.repr.echo
  result = result.copyNimTree

type
  SomeInterface* = concept x
    ## Typeclass that matches every interface.
    isInterface(x)

proc pprintInterface*[T](self: T): string =
  result = "Interface " & name(T)
  let vtable = self.Interface.vtable
  if vtable == nil:
    result &= " nil"
  else:
    result &= " impl " & vtable.typeName

proc isNil*[T: SomeInterface](a: T): bool =
  return a.Interface.vtable == nil

proc implements*(ty: typedesc, superty: typedesc) =
  static:
    if not (ty is superty):
      error(name(ty) & " doesn't implement " & name(superty))

proc getImpl*[T: SomeInterface](iface: T): RootRef =
  ## Returns implementation object of this interface.
  return iface.Interface.obj

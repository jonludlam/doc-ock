(*
 * Copyright (c) 2014 Leo White <lpw25@cl.cam.ac.uk>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Asttypes
open Typedtree

module OCamlPath = Path

open DocOckNames
open DocOckPaths
open DocOckTypes
open DocOckAttrs

module Env = DocOckIdentEnv

let opt_map f = function
  | None -> None
  | Some x -> Some (f x)

let parenthesise name =
  match name with
  | "asr" | "land" | "lnot" | "lor" | "lsl" | "lsr"
  | "lxor" | "mod" -> "(" ^ name ^ ")"
  | _ ->
    if (String.length name > 0) then
      match name.[0] with
      | 'a' .. 'z' | '\223' .. '\246' | '\248' .. '\255' | '_'
      | 'A' .. 'Z' | '\192' .. '\214' | '\216' .. '\222' -> name
      | _ -> "(" ^ name ^ ")"
    else name

let read_label = DocOckCmi.read_label

let rec read_core_type env ctyp =
  let open TypeExpr in
    match ctyp.ctyp_desc with
    | Ttyp_any -> Any
    | Ttyp_var s -> Var s
    | Ttyp_arrow(lbl, arg, res) ->
        let arg = read_core_type env arg in
        let lbl = read_label lbl in
        let res = read_core_type env res in
          Arrow(lbl, arg, res)
    | Ttyp_tuple typs ->
        let typs = List.map (read_core_type env) typs in
          Tuple typs
    | Ttyp_constr(p, _, params) ->
        let p = Env.Path.read_type env p in
        let params = List.map (read_core_type env) params in
          Constr(p, params)
    | Ttyp_object(methods, closed) ->
        let open TypeExpr.Object in
        let fields =
          List.map
#if OCAML_MAJOR = 4 && OCAML_MINOR < 06
            (fun (name, _, typ) -> Method {name; type_ = read_core_type env typ})
#else
            (function
              | OTtag (name, _, typ) ->
                Method {name = name.txt; type_ = read_core_type env typ}
              | OTinherit typ -> Inherit (read_core_type env typ))
#endif
            methods
        in
          Object {fields; open_ = (closed = Asttypes.Open)}
    | Ttyp_class(p, _, params) ->
        let p = Env.Path.read_class_type env p in
        let params = List.map (read_core_type env) params in
          Class(p, params)
    | Ttyp_alias(typ, var) ->
        let typ = read_core_type env typ in
          Alias(typ, var)
    | Ttyp_variant(fields, closed, present) ->
        let open TypeExpr.Variant in
        let elements =
          List.map
            (function
              | Ttag(name, _, const, args) ->
                  let args = List.map (read_core_type env) args in
#if OCAML_MAJOR = 4 && OCAML_MINOR >= 06
                  let name = name.txt in
#endif
                    Constructor(name, const, args)
              | Tinherit typ -> Type (read_core_type env typ))
            fields
        in
        let kind =
          if closed = Asttypes.Open then Open
          else match present with
            | None -> Fixed
            | Some names -> Closed names
        in
          Variant {kind; elements}
    | Ttyp_poly([], typ) -> read_core_type env typ
    | Ttyp_poly(vars, typ) -> Poly(vars, read_core_type env typ)
    | Ttyp_package {pack_path; pack_fields; _} ->
        let open TypeExpr.Package in
        let path = Env.Path.read_module_type env pack_path in
        let substitutions =
          List.map
            (fun (frag, typ) ->
               let frag = Env.Fragment.read_type frag.Location.txt in
               let typ = read_core_type env typ in
               (frag, typ))
            pack_fields
        in
          Package {path; substitutions}

let read_value_description env parent vd =
  let open Signature in
  let name = ValueName.of_ident vd.val_id in
  let id = `Value(parent, name) in
  let doc = read_value_attributes parent id vd.val_attributes in
  let type_ = read_core_type env vd.val_desc in
  match vd.val_prim with
  | [] -> Value {Value.id; doc; type_}
  | primitives -> External {External.id; doc; type_; primitives}

let read_type_parameter (ctyp, var) =
  let open TypeDecl in
  let desc =
    match ctyp.ctyp_desc with
    | Ttyp_any -> Any
    | Ttyp_var s -> Var s
    | _ -> assert false
  in
  let var =
    match var with
    | Covariant -> Some Pos
    | Contravariant -> Some Neg
    | Invariant -> None
  in
    (desc, var)

let read_label_declaration env container parent ld =
  let open TypeDecl.Field in
  let name = FieldName.of_ident ld.ld_id in
  let id = `Field(parent, name) in
  let doc = read_field_attributes container id ld.ld_attributes in
  let mutable_ = (ld.ld_mutable = Mutable) in
  let type_ = read_core_type env ld.ld_type in
    {id; doc; mutable_; type_}

let read_constructor_declaration_arguments env container parent arg =
  let open TypeDecl.Constructor in
    match arg with
    | Cstr_tuple args -> Tuple (List.map (read_core_type env) args)
    | Cstr_record lds ->
        Record (List.map (read_label_declaration env container parent) lds)

let read_constructor_declaration env container parent cd =
  let open TypeDecl.Constructor in
  let name = ConstructorName.of_ident cd.cd_id in
  let id = `Constructor(parent, name) in
  let doc = read_constructor_attributes container id cd.cd_attributes in
  let field_parent = Identifier.FieldParent.of_constructor id in
  let args =
    read_constructor_declaration_arguments env container field_parent cd.cd_args
  in
  let res = opt_map (read_core_type env) cd.cd_res in
    {id; doc; args; res}

let read_type_kind env container parent =
  let open TypeDecl.Representation in function
    | Ttype_abstract -> None
    | Ttype_variant cstrs ->
        let cstrs =
          List.map (read_constructor_declaration env container parent) cstrs
        in
          Some (Variant cstrs)
    | Ttype_record lbls ->
        let field_parent = Identifier.FieldParent.of_type parent in
        let lbls =
          List.map (read_label_declaration env container field_parent) lbls
        in
          Some (Record lbls)
    | Ttype_open -> Some Extensible

let read_type_equation env decl =
  let open TypeDecl.Equation in
  let params = List.map read_type_parameter decl.typ_params in
  let private_ = (decl.typ_private = Private) in
  let manifest = opt_map (read_core_type env) decl.typ_manifest in
  let constraints =
    List.map
      (fun (typ1, typ2, _) ->
         (read_core_type env typ1,
          read_core_type env typ2))
      decl.typ_cstrs
  in
    {params; private_; manifest; constraints}

let read_type_declaration env parent decl =
  let open TypeDecl in
  let name = TypeName.of_ident decl.typ_id in
  let id = `Type(parent, name) in
  let doc = read_type_attributes parent id decl.typ_attributes in
  let equation = read_type_equation env decl in
  let representation = read_type_kind env parent id decl.typ_kind in
    {id; doc; equation; representation}

let read_type_declarations env parent decls =
  let items =
    List.fold_left
      (fun acc decl ->
         let open Signature in
         let comments = read_signature_comments parent decl.typ_attributes in
         let comments = List.map (fun com -> Comment com) comments in
         let decl = read_type_declaration env parent decl in
           (Type decl) :: (List.rev_append comments acc))
      [] decls
  in
    List.rev items

let read_extension_constructor env parent ext =
  let open Extension.Constructor in
  let name = ExtensionName.of_ident ext.ext_id in
  let id = `Extension(parent, name) in
  let doc = read_extension_attributes parent id ext.ext_attributes in
  match ext.ext_kind with
  | Text_rebind _ -> assert false
  | Text_decl(args, res) ->
      let field_parent = Identifier.FieldParent.of_extension id in
      let args =
        read_constructor_declaration_arguments env parent field_parent args
      in
      let res = opt_map (read_core_type env) res in
        {id; doc; args; res}

let read_type_extension env parent tyext =
  let open Extension in
  let type_path = Env.Path.read_type env tyext.tyext_path in
  let doc = read_signature_attributes parent tyext.tyext_attributes in
  let type_params = List.map read_type_parameter tyext.tyext_params in
  let private_ = (tyext.tyext_private = Private) in
  let constructors =
    List.map (read_extension_constructor env parent) tyext.tyext_constructors
  in
    { type_path; doc; type_params; private_; constructors; }

let read_exception env parent ext =
  let open Exception in
  let name = ExceptionName.of_ident ext.ext_id in
  let id = `Exception(parent, name) in
  let doc = read_exception_attributes parent id ext.ext_attributes in
  match ext.ext_kind with
  | Text_rebind _ -> assert false
  | Text_decl(args, res) ->
      let field_parent = Identifier.FieldParent.of_exception id in
      let args =
        read_constructor_declaration_arguments env parent field_parent args
      in
      let res = opt_map (read_core_type env) res in
        {id; doc; args; res}

let rec read_class_type_field env parent ctf =
  let open ClassSignature in
  let doc = read_class_signature_attributes parent ctf.ctf_attributes in
  match ctf.ctf_desc with
  | Tctf_val(name, mutable_, virtual_, typ) ->
      let open InstanceVariable in
      let name = InstanceVariableName.of_string name in
      let id = `InstanceVariable(parent, name) in
      let mutable_ = (mutable_ = Mutable) in
      let virtual_ = (virtual_ = Virtual) in
      let type_ = read_core_type env typ in
        Some (InstanceVariable {id; doc; mutable_; virtual_; type_})
  | Tctf_method(name, private_, virtual_, typ) ->
      let open Method in
      let name = MethodName.of_string name in
      let id = `Method(parent, name) in
      let private_ = (private_ = Private) in
      let virtual_ = (virtual_ = Virtual) in
      let type_ = read_core_type env typ in
        Some (Method {id; doc; private_; virtual_; type_})
  | Tctf_constraint(typ1, typ2) ->
      let typ1 = read_core_type env typ1 in
      let typ2 = read_core_type env typ2 in
        Some (Constraint(typ1, typ2))
  | Tctf_inherit cltyp ->
      Some (Inherit (read_class_signature env parent cltyp))
  | Tctf_attribute attr ->
      match read_class_signature_comment parent attr with
      | None -> None
      | Some doc -> Some (Comment doc)

and read_self_type env typ =
  if typ.ctyp_desc = Ttyp_any then None
  else Some (read_core_type env typ)

and read_class_signature env parent cltyp =
  let open ClassType in
    match cltyp.cltyp_desc with
    | Tcty_constr(p, _, params) ->
        let p = Env.Path.read_class_type env p in
        let params = List.map (read_core_type env) params in
          Constr(p, params)
    | Tcty_signature csig ->
        let open ClassSignature in
        let self = read_self_type env csig.csig_self in
        let items =
          List.fold_left
            (fun rest item ->
               match read_class_type_field env parent item with
               | None -> rest
               | Some item -> item :: rest)
            [] csig.csig_fields
        in
        let items = List.rev items in
          Signature {self; items}
    | Tcty_arrow _ -> assert false
#if OCAML_MAJOR = 4 && OCAML_MINOR >= 06
    | Tcty_open _ -> assert false
#endif

let read_class_type_declaration env parent cltd =
  let open ClassType in
  let name = ClassTypeName.of_ident cltd.ci_id_class_type in
  let id = `ClassType(parent, name) in
  let doc = read_class_type_attributes parent id cltd.ci_attributes in
  let virtual_ = (cltd.ci_virt = Virtual) in
  let params = List.map read_type_parameter cltd.ci_params in
  let parent = Identifier.ClassSignature.of_class_type id in
  let expr = read_class_signature env parent cltd.ci_expr in
  { id; doc; virtual_; params; expr; expansion = None }

let read_class_type_declarations env parent cltds =
  let items =
    List.fold_left
      (fun acc cltd ->
         let open Signature in
         let comments =
           read_signature_comments parent cltd.ci_attributes
         in
         let comments = List.map (fun com -> Comment com) comments in
         let cltd = read_class_type_declaration env parent cltd in
           (ClassType cltd) :: (List.rev_append comments acc))
      [] cltds
  in
    List.rev items

let rec read_class_type env parent cty =
  let open Class in
  match cty.cltyp_desc with
  | Tcty_constr _ | Tcty_signature _ ->
      ClassType (read_class_signature env parent cty)
  | Tcty_arrow(lbl, arg, res) ->
      let lbl = read_label lbl in
      let arg = read_core_type env arg in
      let res = read_class_type env parent res in
        Arrow(lbl, arg, res)
#if OCAML_MAJOR = 4 && OCAML_MINOR >= 06
  | Tcty_open (_, _, _, _, cty) -> read_class_type env parent cty
#endif

let read_class_description env parent cld =
  let open Class in
  let name = ClassName.of_ident cld.ci_id_class in
  let id = `Class(parent, name) in
  let doc = read_class_attributes parent id cld.ci_attributes in
  let virtual_ = (cld.ci_virt = Virtual) in
  let params = List.map read_type_parameter cld.ci_params in
  let parent = Identifier.ClassSignature.of_class id in
  let type_ = read_class_type env parent cld.ci_expr in
  { id; doc; virtual_; params; type_; expansion = None }

let read_class_descriptions env parent clds =
  let items =
    List.fold_left
      (fun acc cld ->
         let open Signature in
         let comments = read_signature_comments parent cld.ci_attributes in
         let comments = List.map (fun com -> Comment com) comments in
         let cld = read_class_description env parent cld in
           (Class cld) :: (List.rev_append comments acc))
      [] clds
  in
    List.rev items

let rec read_with_constraint env (_, frag, constr) =
  let open ModuleType in
    match constr with
    | Twith_type decl ->
        let frag = Env.Fragment.read_type frag.Location.txt in
        let eq = read_type_equation env decl in
          TypeEq(frag, eq)
    | Twith_module(p, _) ->
        let frag = Env.Fragment.read_module frag.Location.txt in
        let eq = read_module_equation env p in
          ModuleEq(frag, eq)
    | Twith_typesubst decl ->
        let frag = Env.Fragment.read_type frag.Location.txt in
        let read_param (ctyp, _) =
          match ctyp.ctyp_desc with
          | Ttyp_var s -> s
          | _ -> assert false
        in
        let params = List.map read_param decl.typ_params in
        let p =
          match decl.typ_manifest with
          | Some {ctyp_desc = Ttyp_constr(p, _, _); _} ->
              Env.Path.read_type env p
          | _ -> assert false
        in
          TypeSubst(frag, params, p)
    | Twith_modsubst(p, _) ->
        let frag = Env.Fragment.read_module frag.Location.txt in
        let p = Env.Path.read_module env p in
          ModuleSubst(frag, p)

and read_module_type env parent mty =
  let open ModuleType in
    match mty.mty_desc with
    | Tmty_ident(p, _) -> Path (Env.Path.read_module_type env p)
    | Tmty_signature sg -> Signature (read_signature env parent sg)
    | Tmty_functor(id, _, param, res) ->
        let param =
          match param with
          | None -> None
          | Some param ->
              let name = FunctorParameterName.of_ident id in
              let id = `FunctorParameter(parent, name) in
              let parent = Identifier.Signature.of_module id in
              let expr = read_module_type env parent param in
              let expansion =
                match expr with
                | Signature _ -> Some Module.AlreadyASig
                | _ -> None
              in
                Some { FunctorParameter. id; expr; expansion }
        in
        let env = Env.add_parameter parent id env in
        let parent = `FunctorResult parent in
        let res = read_module_type env parent res in
          Functor(param, res)
    | Tmty_with(body, subs) ->
        let body = read_module_type env parent body in
        let subs = List.map (read_with_constraint env) subs in
          With(body, subs)
    | Tmty_typeof mexpr ->
        let decl =
          let open Module in
          match mexpr.mod_desc with
          | Tmod_ident(p, _) -> Alias (Env.Path.read_module env p)
          | _ ->
              let mty =
                DocOckCmi.read_module_type env parent mexpr.mod_type
              in
                ModuleType mty
        in
          TypeOf decl
    | Tmty_alias _ -> assert false

and read_module_type_declaration env parent mtd =
  let open ModuleType in
  let name = ModuleTypeName.of_ident mtd.mtd_id in
  let id = `ModuleType(parent, name) in
  let doc = read_module_type_attributes parent id mtd.mtd_attributes in
  let parent = Identifier.Signature.of_module_type id in
  let expr = opt_map (read_module_type env parent) mtd.mtd_type in
  let expansion =
    match expr with
    | Some (Signature _) -> Some Module.AlreadyASig
    | _ -> None
  in
    {id; doc; expr; expansion}

and read_module_declaration env parent md =
  let open Module in
  let name = ModuleName.of_ident md.md_id in
  let id = `Module(parent, name) in
  let doc = read_module_attributes parent id md.md_attributes in
  let parent = Identifier.Signature.of_module id in
  let canonical =
    let open Documentation in
    match doc with
    | Ok { tags; _ } ->
      begin match List.find (function Canonical _ -> true | _ -> false) tags with
      | exception Not_found -> None
      | Canonical p -> Some p
      | _ -> None
      end
    | _ -> None
  in
  let type_ =
    match md.md_type.mty_desc with
    | Tmty_alias(p, _) -> Alias (Env.Path.read_module env p)
    | _ -> ModuleType (read_module_type env parent md.md_type)
  in
  let hidden =
    match canonical with
    | Some _ -> false
    | None -> ModuleName.is_hidden name
  in
  let expansion =
    match type_ with
    | ModuleType (ModuleType.Signature _) -> Some AlreadyASig
    | _ -> None
  in
    {id; doc; type_; expansion; canonical; hidden; display_type = None}

and read_module_declarations env parent mds =
  let items =
    List.fold_left
      (fun acc md ->
         let open Signature in
         let comments = read_signature_comments parent md.md_attributes in
         let comments = List.map (fun com -> Comment com) comments in
         let md = read_module_declaration env parent md in
           (Module md) :: (List.rev_append comments acc))
      [] mds
  in
    List.rev items

and read_module_equation env p =
  let open Module in
    Alias (Env.Path.read_module env p)

and read_signature_item env parent item =
  let open Signature in
    match item.sig_desc with
    | Tsig_value vd ->
        [read_value_description env parent vd]
    | Tsig_type (_rec_flag, decls) -> (* TODO: handle rec flag. *)
        read_type_declarations env parent decls
    | Tsig_typext tyext ->
        [TypExt (read_type_extension env parent tyext)]
    | Tsig_exception ext ->
        [Exception (read_exception env parent ext)]
    | Tsig_module md ->
        [Module (read_module_declaration env parent md)]
    | Tsig_recmodule mds ->
        read_module_declarations env parent mds
    | Tsig_modtype mtd ->
        [ModuleType (read_module_type_declaration env parent mtd)]
    | Tsig_open _ -> []
    | Tsig_include incl ->
        [Include (read_include env parent incl)]
    | Tsig_class cls ->
        read_class_descriptions env parent cls
    | Tsig_class_type cltyps ->
        read_class_type_declarations env parent cltyps
    | Tsig_attribute attr ->
        match read_signature_comment parent attr with
        | None -> []
        | Some doc -> [Comment doc]

and read_include env parent incl =
  let open Include in
  let doc = read_signature_attributes parent incl.incl_attributes in
  let expr = read_module_type env parent incl.incl_mod in
  let decl = Module.ModuleType expr in
  let content = DocOckCmi.read_signature env parent incl.incl_type in
  let expansion = { content; resolved = false} in
    {parent; doc; decl; expansion}

and read_signature env parent sg =
  let env =
    Env.add_signature_tree_items parent sg env
  in
  let items =
    List.fold_left
      (fun items item ->
         List.rev_append (read_signature_item env parent item) items)
      [] sg.sig_items
  in
    List.rev items

let read_interface root name intf =
  let id = `Root(root, name) in
  let items = read_signature Env.empty id intf in
  let doc, items =
    let open Signature in
    let open Documentation in
    match items with
    | Comment (Documentation doc) :: items -> doc, items
    | _ -> empty, items
  in
    (id, doc, items)

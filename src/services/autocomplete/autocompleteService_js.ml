(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Autocomplete_js
open Base.Result
open ServerProt.Response
open Parsing_heaps_utils
open Loc_collections

let add_autocomplete_token contents line column =
  let line = line - 1 in
  let contents_with_token =
    Line.transform_nth contents line (fun line_str ->
        let length = String.length line_str in
        if length >= column then
          let start = String.sub line_str 0 column in
          let end_ = String.sub line_str column (length - column) in
          start ^ Autocomplete_js.autocomplete_suffix ^ end_
        else
          line_str)
  in
  let f (_, x, _) = x in
  let default = "" in
  ( contents_with_token,
    Option.value_map ~f ~default (Line.split_nth contents_with_token (line - 1))
    ^ Option.value_map ~f ~default (Line.split_nth contents_with_token line)
    ^ Option.value_map ~f ~default (Line.split_nth contents_with_token (line + 1)) )

(* the autocomplete token inserts `suffix_len` characters, which are included
 * in `ac_loc` returned by `Autocomplete_js`. They need to be removed before
 * showing `ac_loc` to the client. *)
let remove_autocomplete_token_from_loc loc =
  Loc.{ loc with _end = { loc._end with column = loc._end.column - Autocomplete_js.suffix_len } }

let autocomplete_result_to_json ~strip_root result =
  let func_param_to_json param =
    Hh_json.JSON_Object
      [
        ("name", Hh_json.JSON_String param.param_name);
        ("type", Hh_json.JSON_String param.param_ty);
      ]
  in
  let func_details_to_json details =
    match details with
    | Some fd ->
      Hh_json.JSON_Object
        [
          ("return_type", Hh_json.JSON_String fd.return_ty);
          ("params", Hh_json.JSON_Array (Core_list.map ~f:func_param_to_json fd.param_tys));
        ]
    | None -> Hh_json.JSON_Null
  in
  let name = result.res_name in
  let (ty_loc, ty) = result.res_ty in
  (* This is deprecated for two reasons:
   *   1) The props are still our legacy, flat format rather than grouped into
   *      "loc" and "range" properties.
   *   2) It's the location of the definition of the type (the "type loc"),
   *      which may be interesting but should be its own field. The loc should
   *      instead be the range to replace (usually but not always the token
   *      being completed; perhaps we also want to replace the whole member
   *      expression, for example). That's `result.res_loc`, but we're not
   *      exposing it in the legacy `flow autocomplete` API; use
   *      LSP instead.
   *)
  let deprecated_loc = Errors.deprecated_json_props_of_loc ~strip_root ty_loc in
  Hh_json.JSON_Object
    ( ("name", Hh_json.JSON_String name)
    :: ("type", Hh_json.JSON_String ty)
    :: ("func_details", func_details_to_json result.func_details)
    :: deprecated_loc )

let autocomplete_response_to_json ~strip_root response =
  Hh_json.(
    match response with
    | Error error ->
      JSON_Object
        [
          ("error", JSON_String error);
          ("result", JSON_Array []);
            (* TODO: remove this? kept for BC *)
          
        ]
    | Ok completions ->
      let results = List.map (autocomplete_result_to_json ~strip_root) completions in
      JSON_Object [("result", JSON_Array results)])

let parameter_name is_opt name =
  let opt =
    if is_opt then
      "?"
    else
      ""
  in
  Option.value name ~default:"_" ^ opt

let lsp_completion_of_type =
  Ty.(
    function
    | InterfaceDecl _
    | InlineInterface _ ->
      Some Lsp.Completion.Interface
    | ClassDecl _ -> Some Lsp.Completion.Class
    | StrLit _
    | NumLit _
    | BoolLit _ ->
      Some Lsp.Completion.Value
    | Fun _ -> Some Lsp.Completion.Function
    | TypeAlias _
    | Union _ ->
      Some Lsp.Completion.Enum
    | Module _ -> Some Lsp.Completion.Module
    | Tup _
    | Bot _
    | Null
    | Obj _
    | Inter _
    | TVar _
    | Bound _
    | Generic _
    | Any _
    | Top
    | Void
    | Num _
    | Str _
    | Bool _
    | Arr _
    | TypeOf _
    | Utility _
    | Mu _ ->
      Some Lsp.Completion.Variable)

let autocomplete_create_result ?(show_func_details = true) ?insert_text (name, loc) (ty, ty_loc) =
  let res_ty = (ty_loc, Ty_printer.string_of_t ~with_comments:false ty) in
  let res_kind = lsp_completion_of_type ty in
  Ty.(
    match ty with
    | Fun { fun_params; fun_rest_param; fun_return; _ } when show_func_details ->
      let param_tys =
        Core_list.map
          ~f:(fun (n, t, fp) ->
            let param_name = parameter_name fp.prm_optional n in
            let param_ty = Ty_printer.string_of_t ~with_comments:false t in
            { param_name; param_ty })
          fun_params
      in
      let param_tys =
        match fun_rest_param with
        | None -> param_tys
        | Some (name, t) ->
          let param_name = "..." ^ parameter_name false name in
          let param_ty = Ty_printer.string_of_t ~with_comments:false t in
          param_tys @ [{ param_name; param_ty }]
      in
      let return = Ty_printer.string_of_t ~with_comments:false fun_return in
      {
        res_loc = loc;
        res_kind;
        res_name = name;
        res_insert_text = insert_text;
        res_ty;
        func_details = Some { param_tys; return_ty = return };
      }
    | _ ->
      {
        res_loc = loc;
        res_kind;
        res_name = name;
        res_insert_text = insert_text;
        res_ty;
        func_details = None;
      })

let autocomplete_is_valid_member key =
  (* This is really for being better safe than sorry. It shouldn't happen. *)
  (not (is_autocomplete key))
  (* filter out constructor, it shouldn't be called manually *)
  && (not (key = "constructor"))
  && (* strip out members from prototypes which are implicitly created for
     internal reasons *)
     not (Reason.is_internal_name key)

let ty_normalizer_options =
  Ty_normalizer_env.
    {
      fall_through_merged = true;
      expand_internal_types = true;
      expand_type_aliases = false;
      flag_shadowed_type_params = true;
      preserve_inferred_literal_types = false;
      evaluate_type_destructors = true;
      optimize_types = true;
      omit_targ_defaults = false;
      merge_bot_and_any_kinds = true;
    }

let autocomplete_member
    ~reader
    ~exclude_proto_members
    ?(exclude_keys = SSet.empty)
    ~ac_type
    ?compute_insert_text
    cx
    file_sig
    typed_ast
    this
    ac_name
    ac_loc
    ac_trigger
    docblock
    ~broader_context =
  let ac_loc = loc_of_aloc ~reader ac_loc |> remove_autocomplete_token_from_loc in
  let result = Members.extract ~exclude_proto_members cx this in
  Hh_json.(
    let (result_str, t) =
      Members.(
        match result with
        | Success _ -> ("SUCCESS", this)
        | SuccessModule _ -> ("SUCCESS", this)
        | FailureNullishType -> ("FAILURE_NULLABLE", this)
        | FailureAnyType -> ("FAILURE_NO_COVERAGE", this)
        | FailureUnhandledType t -> ("FAILURE_UNHANDLED_TYPE", t)
        | FailureUnhandledMembers t -> ("FAILURE_UNHANDLED_MEMBERS", t))
    in
    let json_data_to_log =
      JSON_Object
        [
          ("ac_type", JSON_String ac_type);
          ("ac_name", JSON_String ac_name);
          (* don't need to strip root for logging *)
            ("ac_loc", JSON_Object (Errors.deprecated_json_props_of_loc ~strip_root:None ac_loc));
          ("ac_trigger", JSON_String (Option.value ac_trigger ~default:"None"));
          ("loc", Reason.json_of_loc ~offset_table:None ac_loc);
          ("docblock", Docblock.json_of_docblock docblock);
          ("result", JSON_String result_str);
          ("type", Debug_js.json_of_t ~depth:3 cx t);
          ("broader_context", JSON_String broader_context);
        ]
    in
    match Members.to_command_result result with
    | Error error -> Error (error, Some json_data_to_log)
    | Ok result_map ->
      let file = Context.file cx in
      let genv = Ty_normalizer_env.mk_genv ~full_cx:cx ~file ~typed_ast ~file_sig in
      let rev_result =
        SMap.fold
          (fun name (_id_loc, t) acc ->
            if (not (autocomplete_is_valid_member name)) || SSet.mem name exclude_keys then
              acc
            else
              let loc = Type.loc_of_t t |> loc_of_aloc ~reader in
              ((name, loc), t) :: acc)
          result_map
          []
      in
      let result =
        rev_result
        |> Ty_normalizer.from_types ~options:ty_normalizer_options ~genv
        |> Core_list.rev_filter_map ~f:(function
               | ((name, ty_loc), Ok ty) ->
                 Some
                   (autocomplete_create_result
                      ?insert_text:(Option.map ~f:(fun f -> f name) compute_insert_text)
                      (name, ac_loc)
                      (ty, ty_loc))
               | _ -> None)
      in
      Ok (result, Some json_data_to_log))

(* turns typed AST into normal AST so we can run Scope_builder on it *)
(* TODO(vijayramamurthy): make scope builder polymorphic *)
class type_killer (reader : Parsing_heaps.Reader.reader) =
  object
    inherit [ALoc.t, ALoc.t * Type.t, Loc.t, Loc.t] Flow_polymorphic_ast_mapper.mapper

    method on_loc_annot x = loc_of_aloc ~reader x

    method on_type_annot (x, _) = loc_of_aloc ~reader x
  end

(* The fact that we need this feels convoluted.
    We started with a typed AST, then stripped the types off of it to run Scope_builder on it,
    and now we go back to the typed AST to get the types of the locations we got from Scope_api.
    We wouldn't need to do this separate pass if Scope_builder/Scope_api were polymorphic.
 *)
class type_collector (reader : Parsing_heaps.Reader.reader) (locs : LocSet.t) =
  object
    inherit [ALoc.t, ALoc.t * Type.t, ALoc.t, ALoc.t * Type.t] Flow_polymorphic_ast_mapper.mapper

    val mutable acc = LocMap.empty

    method on_loc_annot x = x

    method on_type_annot x = x

    method collected_types = acc

    method! t_identifier (((aloc, t), _) as ident) =
      let loc = loc_of_aloc ~reader aloc in
      if LocSet.mem loc locs then acc <- LocMap.add loc t acc;
      ident
  end

let collect_types ~reader locs typed_ast =
  let collector = new type_collector reader locs in
  Pervasives.ignore (collector#program typed_ast);
  collector#collected_types

(* env is all visible bound names at cursor *)
let autocomplete_id ~reader cx ac_loc ac_trigger ~id_type file_sig typed_ast ~broader_context =
  let ac_loc = loc_of_aloc ~reader ac_loc |> remove_autocomplete_token_from_loc in
  let scope_info = Scope_builder.program ((new type_killer reader)#program typed_ast) in
  let open Scope_api.With_Loc in
  (* get the innermost scope enclosing the requested location *)
  let (ac_scope_id, _) =
    IMap.fold
      (fun this_scope_id this_scope (prev_scope_id, prev_scope) ->
        if
          Reason.in_range ac_loc this_scope.Scope.loc
          && Reason.in_range this_scope.Scope.loc prev_scope.Scope.loc
        then
          (this_scope_id, this_scope)
        else
          (prev_scope_id, prev_scope))
      scope_info.scopes
      (0, scope scope_info 0)
  in
  (* gather all in-scope variables *)
  let names_and_locs =
    fold_scope_chain
      scope_info
      (fun _ scope acc ->
        let scope_vars = scope.Scope.defs |> SMap.map (fun Def.{ locs; _ } -> Nel.hd locs) in
        (* don't suggest lexically-scoped variables declared after the current location.
          this filtering isn't perfect:

            let foo = /* request here */
                ^^^
                def_loc

          since def_loc is the location of the identifier within the declaration statement
          (not the entire statement), we don't filter out foo when declaring foo. *)
        let relevant_scope_vars =
          if scope.Scope.lexical then
            SMap.filter (fun _name def_loc -> Loc.compare def_loc ac_loc < 0) scope_vars
          else
            scope_vars
        in
        SMap.union acc relevant_scope_vars)
      ac_scope_id
      SMap.empty
  in
  let types = collect_types ~reader (LocSet.of_list (SMap.values names_and_locs)) typed_ast in
  let normalize_type =
    Ty_normalizer.from_type
      ~options:ty_normalizer_options
      ~genv:(Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig)
  in
  let (results, errors) =
    SMap.fold
      (fun name loc (results, errors) ->
        match normalize_type (LocMap.find loc types) with
        | Ok ty ->
          let result =
            autocomplete_create_result
              ~show_func_details:(id_type <> JSXIdent)
              (name, ac_loc)
              (ty, loc)
          in
          (result :: results, errors)
        | Error error -> (results, error :: errors))
      names_and_locs
      ([], [])
  in
  let json_data_to_log =
    Hh_json.(
      let result_str =
        match (results, errors) with
        | (_, []) -> "SUCCESS"
        | ([], _) -> "FAILURE_NORMALIZER"
        | (_, _) -> "PARTIAL"
      in
      JSON_Object
        [
          ("ac_type", JSON_String "Acid");
          ("ac_trigger", JSON_String (Option.value ac_trigger ~default:"None"));
          ("result", JSON_String result_str);
          ("count", JSON_Number (results |> List.length |> string_of_int));
          ( "errors",
            JSON_Array
              (Core_list.rev_map errors ~f:(fun err ->
                   JSON_String (Ty_normalizer.error_to_string err))) );
          ("broader_context", JSON_String broader_context);
        ])
  in
  Ok (results, Some json_data_to_log)

(* Similar to autocomplete_member, except that we're not directly given an
   object type whose members we want to enumerate: instead, we are given a
   component class and we want to enumerate the members of its declared props
   type, so we need to extract that and then route to autocomplete_member. *)
let autocomplete_jsx
    ~reader
    cx
    file_sig
    typed_ast
    cls
    ac_name
    ~used_attr_names
    ac_loc
    ac_trigger
    docblock
    ~broader_context =
  Flow_js.(
    let reason = Reason.mk_reason (Reason.RCustom ac_name) ac_loc in
    let props_object =
      Tvar.mk_where cx reason (fun tvar ->
          let use_op = Type.Op Type.UnknownUse in
          flow cx (cls, Type.ReactKitT (use_op, reason, Type.React.GetConfig tvar)))
    in
    (* The `children` prop (if it exists) is set with the contents between the opening and closing
     * elements, rather than through an explicit `children={...}` attribute, so we should exclude
     * it from the autocomplete results, along with already used attribute names. *)
    let exclude_keys = SSet.add "children" used_attr_names in
    (* Only include own properties, so we don't suggest things like `hasOwnProperty` as potential JSX properties *)
    autocomplete_member
      ~reader
      ~exclude_proto_members:true
      ~exclude_keys
      ~ac_type:"Acjsx"
      ~compute_insert_text:(fun name -> name ^ "=")
      cx
      file_sig
      typed_ast
      props_object
      ac_name
      ac_loc
      ac_trigger
      docblock
      ~broader_context)

let autocomplete_get_results
    ~reader cx file_sig typed_ast trigger_character docblock ~broader_context =
  let file_sig = File_sig.abstractify_locs file_sig in
  match Autocomplete_js.process_location ~trigger_character ~typed_ast with
  | Some (Acid (ac_loc, id_type)) ->
    autocomplete_id
      ~reader
      cx
      ac_loc
      trigger_character
      ~id_type
      file_sig
      typed_ast
      ~broader_context
  | Some (Acmem (ac_name, ac_loc, this)) ->
    autocomplete_member
      ~reader
      ~exclude_proto_members:false
      ~ac_type:"Acmem"
      cx
      file_sig
      typed_ast
      this
      ac_name
      ac_loc
      trigger_character
      docblock
      ~broader_context
  | Some (Acjsx (ac_name, used_attr_names, ac_loc, cls)) ->
    autocomplete_jsx
      ~reader
      cx
      file_sig
      typed_ast
      cls
      ac_name
      ~used_attr_names
      ac_loc
      trigger_character
      docblock
      ~broader_context
  | None ->
    let json_data_to_log =
      Hh_json.(
        JSON_Object
          [
            ("ac_type", JSON_String "None");
            ("ac_trigger", JSON_String (Option.value trigger_character ~default:"None"));
            ("broader_context", JSON_String broader_context);
          ])
    in
    Ok ([], Some json_data_to_log)

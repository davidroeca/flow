(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Reason
open Type

module type OBJECT = sig
  val run :
    Context.t ->
    Trace.t ->
    use_op:Type.use_op ->
    Reason.t ->
    Type.Object.resolve_tool ->
    Type.Object.tool ->
    Type.t ->
    Type.t ->
    unit

  val widen_obj_type :
    Context.t -> ?trace:Trace.t -> use_op:Type.use_op -> Reason.reason -> Type.t -> Type.t
end

module Kit (Flow : Flow_common.S) : OBJECT = struct
  include Flow

  exception CannotSpreadError of Error_message.t

  let widen_obj_type cx ?trace ~use_op reason t =
    match t with
    | OpenT (r, id) ->
      let open Constraint in
      begin
        match Context.find_graph cx id with
        | Unresolved _ ->
          let open Object in
          let widened_id = Tvar.mk_no_wrap cx r in
          let tout = OpenT (r, widened_id) in
          flow_opt
            cx
            ?trace
            (t, ObjKitT (use_op, reason, Resolve Next, ObjectWiden widened_id, tout));
          tout
        | Resolved (_, t)
        | FullyResolved (_, t) ->
          widen_obj_type cx ?trace ~use_op reason t
      end
    | UnionT (r, rep) ->
      UnionT
        ( r,
          UnionRep.ident_map
            (fun t ->
              if is_proper_def t then
                widen_obj_type cx ?trace ~use_op reason t
              else
                t)
            rep )
    | t -> t

  let type_optionality_and_missing_property (t, _) =
    match t with
    | OptionalT { reason; type_ = t; use_desc } ->
      let is_missing_property_desc =
        match desc_of_reason reason with
        | RPossiblyMissingPropFromObj _ -> true
        | _ -> false
      in
      (t, true, use_desc && is_missing_property_desc)
    | _ -> (t, false, false)

  (* Widening may create optional props because a property may not exist on some object. This
   * synthetic property lacks a good location in the code, since it represents the absence
   * of a key in some object. In order to point to a good location, we point to the object
   * missing the property in the reason desc. *)
  let possibly_missing_prop propname obj_reason type_ =
    let reason =
      update_desc_new_reason (fun desc -> RPossiblyMissingPropFromObj (propname, desc)) obj_reason
    in
    OptionalT { reason; type_; use_desc = true }

  (* When a property is optional due to widening (see possibly_missing_prop), we want to make sure
   * that the reason it is missing persists through interactions with other optional properties.
   *
   * This function preserves the possibly missing prop reason if it existed on both 
   * of the optional properties. Otherwise, we have an explicit optional property, which
   * is better to use.
   *)
  let make_optional_with_possible_missing_props propname missing_prop1 missing_prop2 r =
    if missing_prop1 && missing_prop2 then
      possibly_missing_prop propname r
    else
      optional ?annot_loc:None ~use_desc:false

  let run =
    Object.(
      (*******************************)
      (* Shared Object Kit Utilities *)
      (*******************************)
      let read_prop r flags x p =
        let t =
          match Property.read_t p with
          | Some t -> t
          | None ->
            let reason = replace_desc_reason (RUnknownProperty (Some x)) r in
            let t = DefT (reason, bogus_trust (), MixedT Mixed_everything) in
            t
        in
        (t, flags.exact)
      in
      let read_dict r { value; dict_polarity; _ } =
        if Polarity.compat (dict_polarity, Polarity.Positive) then
          value
        else
          let reason = replace_desc_reason (RUnknownProperty None) r in
          DefT (reason, bogus_trust (), MixedT Mixed_everything)
      in
      (* Treat dictionaries as optional, own properties. Dictionary reads should
       * be exact. TODO: Forbid writes to indexers through the photo chain.
       * Property accesses which read from dictionaries normally result in a
       * non-optional result, but that leads to confusing spread results. For
       * example, `p` in `{...{|p:T|},...{[]:U}` should `T|U`, not `U`. *)
      let get_prop r p dict =
        match (p, dict) with
        | (Some _, _) -> p
        | (None, Some d) -> Some (optional (read_dict r d), true)
        | (None, None) -> None
      in
      (* Lift a pairwise function to a function over a resolved list *)
      let merge (f : slice -> slice -> slice) =
        let f' (x0 : resolved) (x1 : resolved) =
          Nel.map_concat (fun slice1 -> Nel.map (f slice1) x0) x1
        in
        let rec loop x0 = function
          | [] -> x0
          | x1 :: xs -> loop (f' x0 x1) xs
        in
        (fun x0 (x1, xs) -> loop (f' x0 x1) xs)
      in
      (* Lift a pairwise function that may return an error to a function over a resolved list
       * that may return an error, like spread2 *)
      let merge_result (f : 'a -> 'a -> ('a, Error_message.t) result) (conv : 'b -> 'a Nel.t) =
        let bind f = function
          | Ok data -> f data
          | Error e -> Error e
        in
        let mapM f = function
          | Ok data -> Ok (f data)
          | Error e -> Error e
        in
        let f' (x0 : 'a Nel.t) (x1 : 'b) : ('a Nel.t, Error_message.t) result =
          let x1 = conv x1 in
          let resolved_list =
            Nel.fold_left
              (fun acc slice1 ->
                bind
                  (fun acc ->
                    let resolved =
                      Nel.fold_left
                        (fun acc x ->
                          bind (fun acc -> bind (fun slice -> Ok (slice :: acc)) (f x slice1)) acc)
                        (Ok [])
                        x0
                    in
                    let resolved = resolved |> mapM List.rev in
                    bind (fun resolved -> Ok (resolved :: acc)) resolved)
                  acc)
              (Ok [])
              x1
          in
          let resolved_list = resolved_list |> mapM List.rev in
          (* Each of the lists were non-empty, so concatenating them creates a non-empty list. Thus,
           * Nel.of_list_exn is safe *)
          bind (fun lists -> Ok (Nel.of_list_exn (Base.List.join lists))) resolved_list
        in
        let rec loop (x0 : 'a Nel.t) (xs : 'b list) =
          match xs with
          | [] -> Ok x0
          | x1 :: xs -> bind (fun resolved -> loop resolved xs) (f' x0 x1)
        in
        (fun x0 (x1, xs) -> bind (fun resolved -> loop resolved xs) (f' (conv x0) x1))
      in
      (*****************)
      (* Object Spread *)
      (*****************)
      let object_spread =
        Object.Spread.(
          (* Compute spread result
           * We keep around a few pieces of extra information in addition to the slices:
           * 1. Whether or not the slice was declared in line
           * 2. The most recent reason that the accumulator (object on the left) is inexact
           *
           * 1. Lets us infer types in spreads that are more inline with user expectations
           * by allowing inline declarations to overwrite properties on the left that
           * would cause an error if they were not inline. For example:
           * {...{| foo: number |}}, [string]: string}. If we did not account
           * for inline declarations, this spread would be an error even though there
           * is a reasonable way to interpret the type.
           *
           * 2. Lets us write better error messages when we spread an object with an optional
           * property after an inexact object. The accumulator may be inexact because we encountered
           * an inexact object earlier in the spread, but the reason for the accumulator refers to
           * the entire spread. Instead of pointing to that reason as the inexact object, we
           * can keep track of the most recently seen inexact object and point to that instead.
           *
           * We still have room for improvement for the error messages here. When we spread
           * an inexact object on the right, we may overwrite keys that came before, so
           * we error. Unfortunately, we point to the accumulator (the entire sperad) and say that
           * a key in the accumulator may be overwritten by the inexact object spread. That
           * is a little confusing when you have types like these:
           *
           * type A = {| foo: number |};
           * type B = {| bar: number |};
           * type C = {baz: number};
           * [1] type D = {...A, ...B, ...C} // Error, C is inexact and may overwrite foo in [1]
           *              ^^^^^^^^^^^^^^^^^
           *)
          let spread2
              reason
              ( _inline1,
                inexact_reason1,
                { Object.reason = r1; props = props1; dict = dict1; flags = flags1 } )
              ( inline2,
                _inexact_reason2,
                { Object.reason = r2; props = props2; dict = dict2; flags = flags2 } ) =
            let dict =
              match (dict1, dict2) with
              | (None, Some _) when inline2 -> Ok dict2
              | (_, Some { key; value = _; dict_name = _; dict_polarity = _ }) ->
                Error
                  (Error_message.ECannotSpreadIndexerOnRight
                     { spread_reason = reason; object_reason = r2; key_reason = reason_of_t key })
              | (Some { key; value; dict_name = _; dict_polarity = _ }, _) when not flags2.exact ->
                Error
                  (Error_message.EInexactMayOverwriteIndexer
                     {
                       spread_reason = reason;
                       key_reason = reason_of_t key;
                       value_reason = reason_of_t value;
                       object2_reason = r2;
                     })
              | _ -> Ok dict1
            in
            match dict with
            | Error e -> Error e
            | Ok dict ->
              let union t1 t2 = UnionT (reason, UnionRep.make t1 t2 []) in
              let merge_props propname t1 t2 =
                let (t1, opt1, missing_prop1) = type_optionality_and_missing_property t1 in
                let (t2, opt2, missing_prop2) = type_optionality_and_missing_property t2 in
                if not opt2 then
                  (t2, true)
                else if opt1 && opt2 then
                  ( make_optional_with_possible_missing_props
                      propname
                      missing_prop1
                      missing_prop2
                      r1
                      (union t1 t2),
                    true )
                (* In this case, we know opt2 is true and opt1 is false *)
                else
                  (union t1 t2, true)
              in
              let props =
                try
                  Ok
                    (SMap.merge
                       (fun x p1 p2 ->
                         match (p1, p2) with
                         | (None, None) -> None
                         | (_, Some p2) when inline2 -> Some (fst p2, true)
                         | (Some p1, Some p2) -> Some (merge_props x p1 p2)
                         | (Some p1, None) ->
                           if flags2.exact then
                             Some (fst p1, true)
                           else
                             raise
                               (CannotSpreadError
                                  (Error_message.EUnableToSpread
                                     {
                                       spread_reason = reason;
                                       object1_reason = r1;
                                       object2_reason = r2;
                                       propname = x;
                                       error_kind = Error_message.Inexact;
                                     }))
                         (* We care about a few cases here. We want to make sure that we can
                          * infer a precise type. This is tricky when the left-hand slice is inexact,
                          * since it may contain p2 even though it's not explicitly specified.
                          *
                          * If p2 is not optional, then we won't have to worry about anything because it will
                          * definitely overwrite a property with a key matching p2's on the left.
                          *
                          * If p2 is optional, then we can split into a few more cases:
                          *   1. o1 is inexact: error, we cannot infer a precise type since o1 might contain p2
                          *   2. o1 has an indexer: error, we would have to infer a union with the indexer type.
                          *      This would be sound, but it's not likely that anyone would intend it. If that
                          *      assumption turns out to be false, we can easily add support for it later.
                          *   3. o1 is exact: no problem, we don't need to worry about o1 having the
                          *      same property.
                          *
                          *  The if statement below handles 1. and 2., and the else statement
                          *  handles 3. and the case when p2 is not optional.
                          *)
                         | (None, Some p2) ->
                           let (_, opt2, _) = type_optionality_and_missing_property p2 in
                           if (dict1 <> None || not flags1.exact) && opt2 then
                             let error_kind =
                               if dict1 <> None then
                                 Error_message.Indexer
                               else
                                 Error_message.Inexact
                             in
                             let inexact_reason =
                               match inexact_reason1 with
                               | None -> r1
                               | Some r -> r
                             in
                             raise
                               (CannotSpreadError
                                  (Error_message.EUnableToSpread
                                     {
                                       spread_reason = reason;
                                       (* in this case, the object on the left is inexact. the error will say
                                        * that object2_reason is inexact and may contain propname, so
                                        * we should assign r2 to object1_reason and inexact_reason to object2_reason *)
                                       object1_reason = r2;
                                       object2_reason = inexact_reason;
                                       propname = x;
                                       error_kind;
                                     }))
                           else
                             Some (fst p2, true))
                       props1
                       props2)
                with CannotSpreadError e -> Error e
              in
              let flags =
                {
                  frozen = flags1.frozen && flags2.frozen;
                  sealed = Sealed;
                  exact =
                    flags1.exact
                    && flags2.exact
                    && Obj_type.sealed_in_op reason flags1.sealed
                    && Obj_type.sealed_in_op reason flags2.sealed;
                }
              in
              let inexact_reason =
                match (flags1.exact, flags2.exact) with
                (* If the inexact reason is None, that means we still haven't hit an inexact object yet, so we can
                 * take that reason to propagate as the reason for the accumulator's inexactness.
                 *
                 * If it's already Some r, then the reason the object on the left is inexact
                 * is because of an earlier inexact object. We would have already encountered that inexact
                 * object on the right in a previous iteration of spread2, so the next case in the
                 * match would have already updated the inexact reason to the most recent inexact object.
                 * The only exception to this rule is if the first object is inexact, in which case
                 * inexact_reason1 is already None anyway.
                 *)
                | (false, true) when inexact_reason1 = None -> Some r1
                | (_, false) -> Some r2
                | _ -> inexact_reason1
              in
              (match props with
              | Ok props -> Ok (false, inexact_reason, { Object.reason; props; dict; flags })
              | Error e -> Error e)
          in
          let resolved_of_acc_element = function
            | Object.Spread.ResolvedSlice resolved -> Nel.map (fun x -> (false, None, x)) resolved
            | Object.Spread.InlineSlice { Object.Spread.reason; prop_map; dict } ->
              let flags = { exact = true; frozen = false; sealed = Sealed } in
              let props = SMap.mapi (read_prop reason flags) prop_map in
              Nel.one (true, None, { Object.reason; props; dict; flags })
          in
          let spread reason = function
            | (x, []) -> Ok (resolved_of_acc_element x)
            | (x0, (x1 :: xs : Object.Spread.acc_element list)) ->
              merge_result (spread2 reason) resolved_of_acc_element x0 (x1, xs)
          in
          let mk_object cx reason target { Object.reason = _; props; dict; flags } =
            let props = SMap.map (fun (t, _) -> Field (None, t, Polarity.Neutral)) props in
            let id = Context.generate_property_map cx props in
            let proto = ObjProtoT reason in
            let flags =
              let (exact, sealed) =
                match target with
                (* Type spread result is exact if annotated to be exact *)
                | Annot { make_exact } -> (make_exact, Sealed)
                (* Value spread result is exact if all inputs are exact *)
                | Value { make_seal } -> (flags.exact, make_seal)
              in
              { sealed; frozen = false; exact }
            in
            let call = None in
            let t = mk_object_def_type ~reason ~flags ~dict ~call id proto in
            (* Wrap the final type in an `ExactT` if we have an exact flag *)
            if flags.exact then
              ExactT (reason, t)
            else
              t
          in
          fun options state cx trace use_op reason tout x ->
            let reason = update_desc_reason invalidate_rtype_alias reason in
            let { todo_rev; acc; spread_id; union_reason; curr_resolve_idx } = state in
            Nel.iter
              (fun { Object.reason = r; props = _; dict = _; flags = { exact; _ } } ->
                match options with
                | Annot { make_exact } when make_exact && not exact ->
                  add_output cx ~trace (Error_message.EIncompatibleWithExact ((r, reason), use_op))
                | _ -> ())
              x;
            let resolved = Object.Spread.ResolvedSlice x in
            let rec continue acc (resolved : Object.Spread.acc_element) curr_resolve_idx = function
              | [] ->
                let t =
                  match spread reason (resolved, acc) with
                  | Ok ((_, _, x), []) -> mk_object cx reason options x
                  | Ok ((_, _, x0), (_, _, x1) :: xs) ->
                    let xs = List.map (fun (_, _, x) -> x) xs in
                    UnionT
                      ( reason,
                        UnionRep.make
                          (mk_object cx reason options x0)
                          (mk_object cx reason options x1)
                          (Base.List.map ~f:(mk_object cx reason options) xs) )
                  | Error e ->
                    add_output cx ~trace e;
                    AnyT.why AnyError reason
                in
                (* Intentional UnknownUse here. *)
                rec_flow_t cx ~use_op trace (t, tout)
              | Type t :: todo_rev ->
                let tool = Resolve Next in
                let state =
                  {
                    todo_rev;
                    acc = resolved :: acc;
                    spread_id;
                    union_reason = None;
                    curr_resolve_idx;
                  }
                in
                let l = widen_obj_type cx ~trace ~use_op reason t in
                rec_flow cx trace (l, ObjKitT (use_op, reason, tool, Spread (options, state), tout))
              | Slice operand_slice :: todo_rev ->
                let acc = resolved :: acc in
                continue acc (InlineSlice operand_slice) (curr_resolve_idx + 1) todo_rev
            in
            (* Before proceeding to the next spread step, we need to ensure that we aren't going to hit
             * exponential blowup due to multiple spread operands having multiple lower bounds. To do
             * that, we increment the amount of lower bounds found at this resolution index by
             * the amount of lower bounds found at this index. If multiple indices have multiple lower
             * bounds, Cache.Spread.can_spread will return false and we can error instead of proceeding.
             *
             * Any other latent constraints involving this spread_id will also stop when they hit this
             * logic.
             *)
            let prev_can_spread = Flow_cache.Spread.can_spread spread_id in
            if not prev_can_spread then
              ()
            else (
              begin
                match (union_reason, x) with
                | (None, x) ->
                  Nel.iter
                    (fun ({ Object.reason; _ } as slice) ->
                      Flow_cache.Spread.add_lower_bound
                        spread_id
                        curr_resolve_idx
                        reason
                        (Nel.one slice))
                    x
                | (Some reason, _) ->
                  Flow_cache.Spread.add_lower_bound spread_id curr_resolve_idx reason x
              end;
              let can_spread = Flow_cache.Spread.can_spread spread_id in
              if prev_can_spread && not can_spread then (
                let (reasons_for_operand1, reasons_for_operand2) =
                  Flow_cache.Spread.get_error_groups spread_id
                in
                add_output
                  cx
                  ~trace
                  (Error_message.EExponentialSpread
                     { reason; reasons_for_operand1; reasons_for_operand2 });
                rec_flow_t cx trace ~use_op (AnyT.why AnyError reason, tout)
              ) else
                continue acc resolved (curr_resolve_idx + 1) todo_rev
            ))
      in
      (***************)
      (* Object Rest *)
      (***************)
      let object_rest =
        Object.Rest.(
          let optional = function
            | OptionalT _ as t -> t
            | t -> Type.optional t
          in
          (* Subtract the second slice from the first slice and return the difference
           * slice. The runtime implementation of this type operation is:
           *
           *     const result = {};
           *
           *     for (const p in props1) {
           *       if (hasOwnProperty(props1, p)) {
           *         if (!hasOwnProperty(props2, p)) {
           *           result[p] = props1[p];
           *         }
           *       }
           *     }
           *
           * The resulting object only has a property if the property is own in props1 and
           * it is not an own property of props2.
           *)
          let rest
              cx
              trace
              ~use_op
              reason
              merge_mode
              { Object.reason = r1; props = props1; dict = dict1; flags = flags1 }
              { Object.reason = r2; props = props2; dict = dict2; flags = flags2 } =
            let props =
              SMap.merge
                (fun k p1 p2 ->
                  match (merge_mode, get_prop r1 p1 dict1, get_prop r2 p2 dict2, flags2.exact) with
                  (* If the object we are using to subtract has an optional property, non-own
                   * property, or is inexact then we should add this prop to our result, but
                   * make it optional as we cannot know for certain whether or not at runtime
                   * the property would be subtracted.
                   *
                   * Sound subtraction also considers exactness and owness to determine
                   * optionality. If p2 is maybe-own then sometimes it may not be
                   * subtracted and so is optional. If props2 is not exact then we may
                   * optionally have some undocumented prop. *)
                  | ((Sound | IgnoreExactAndOwn), Some (t1, _), Some ((OptionalT _ as t2), _), _)
                  | (Sound, Some (t1, _), Some (t2, false), _)
                  | (Sound, Some (t1, _), Some (t2, _), false) ->
                    rec_flow cx trace (t1, UseT (use_op, optional t2));
                    Some (Field (None, optional t1, Polarity.Neutral))
                  (* Otherwise if the object we are using to subtract has a non-optional own
                   * property and the object is exact then we never add that property to our
                   * source object. *)
                  | ((Sound | IgnoreExactAndOwn), None, Some (t2, _), _) ->
                    let reason = replace_desc_reason (RUndefinedProperty k) r1 in
                    rec_flow
                      cx
                      trace
                      (VoidT.make reason |> with_trust bogus_trust, UseT (use_op, t2));
                    None
                  | ((Sound | IgnoreExactAndOwn), Some (t1, _), Some (t2, _), _) ->
                    rec_flow cx trace (t1, UseT (use_op, t2));
                    None
                  (* If we have some property in our first object and none in our second
                   * object, but our second object is inexact then we want to make our
                   * property optional and flow that type to mixed. *)
                  | (Sound, Some (t1, _), None, false) ->
                    rec_flow cx trace (t1, UseT (use_op, MixedT.make r2 |> with_trust bogus_trust));
                    Some (Field (None, optional t1, Polarity.Neutral))
                  (* If neither object has the prop then we don't add a prop to our
                   * result here. *)
                  | ((Sound | IgnoreExactAndOwn | ReactConfigMerge _), None, None, _) -> None
                  (* If our first object has a prop and our second object does not have that
                   * prop then we will copy over that prop. If the first object's prop is
                   * non-own then sometimes we may not copy it over so we mark it
                   * as optional. *)
                  | (IgnoreExactAndOwn, Some (t, _), None, _) ->
                    Some (Field (None, t, Polarity.Neutral))
                  | (ReactConfigMerge _, Some (t, _), None, _) ->
                    Some (Field (None, t, Polarity.Positive))
                  | (Sound, Some (t, true), None, _) -> Some (Field (None, t, Polarity.Neutral))
                  | (Sound, Some (t, false), None, _) ->
                    Some (Field (None, optional t, Polarity.Neutral))
                  (* React config merging is special. We are trying to solve for C
                   * in the equation (where ... represents spread instead of rest):
                   *
                   *     {...DP, ...C} = P
                   *
                   * Where DP and P are known. Consider this case:
                   *
                   *     {...{p?}, ...C} = {p}
                   *
                   * The solution for C here is {p} instead of {p?} since
                   * {...{p?}, ...{p?}} is {p?} instead of {p}. This is inconsistent with
                   * the behavior of other object rest merge modes implemented in this
                   * pattern match. *)
                  | ( ReactConfigMerge _,
                      Some (t1, _),
                      Some (OptionalT { reason = _; type_ = t2; use_desc = _ }, _),
                      _ ) ->
                    (* We only test the subtyping relation of t1 and t2 if both t1 and t2
                     * are optional types. If t1 is required then t2 will always
                     * be overwritten. *)
                    (match t1 with
                    | OptionalT { reason = _; type_ = t1; use_desc = _ } ->
                      rec_flow_t cx trace (t2, t1)
                    | _ -> ());
                    Some (Field (None, t1, Polarity.Positive))
                  (* Using our same equation. Consider this case:
                   *
                   *     {...{p}, ...C} = {p}
                   *
                   * The solution for C here is {p?}. An empty object, {}, is not a valid
                   * solution unless that empty object is exact. Even for exact objects,
                   * {|p?|} is the best solution since it accepts more valid
                   * programs then {||}. *)
                  | (ReactConfigMerge _, Some (t1, _), Some (t2, _), _) ->
                    (* The DP type for p must be a subtype of the P type for p. *)
                    rec_flow_t cx trace (t2, t1);
                    Some (Field (None, optional t1, Polarity.Positive))
                  (* Consider this case:
                   *
                   *     {...{p}, ...C} = {}
                   *
                   * For C there will be no prop. However, if the props object is exact
                   * then we need to throw an error. *)
                  | (ReactConfigMerge _, None, Some (_, _), _) ->
                    ( if flags1.exact then
                      let use_op =
                        Frame
                          ( PropertyCompatibility { prop = Some k; lower = r2; upper = r1 },
                            unknown_use )
                      in
                      let r2 = replace_desc_reason (RProperty (Some k)) r2 in
                      let err = Error_message.EPropNotFound (Some k, (r2, r1), use_op) in
                      add_output cx ~trace err );
                    None)
                props1
                props2
            in
            let dict =
              match (dict1, dict2) with
              | (None, None) -> None
              | (Some dict, None) -> Some dict
              | (None, Some _) -> None
              (* If our first and second objects have a dictionary then we use our first
               * dictionary, but we make the value optional since any set of keys may have
               * been removed. *)
              | (Some dict1, Some dict2) ->
                rec_flow cx trace (dict1.value, UseT (use_op, dict2.value));
                Some
                  {
                    dict_name = None;
                    key = dict1.key;
                    value = optional dict1.value;
                    dict_polarity = Polarity.Neutral;
                  }
            in
            let flags =
              {
                frozen = false;
                sealed = Sealed;
                exact = flags1.exact && Obj_type.sealed_in_op reason flags1.sealed;
              }
            in
            let id = Context.generate_property_map cx props in
            let proto = ObjProtoT r1 in
            let call = None in
            let t = mk_object_def_type ~reason:r1 ~flags ~dict ~call id proto in
            (* Wrap the final type in an `ExactT` if we have an exact flag *)
            if flags.exact then
              ExactT (r1, t)
            else
              t
          in
          fun options state cx trace use_op reason tout x ->
            match state with
            | One t ->
              let tool = Resolve Next in
              let state = Done x in
              rec_flow cx trace (t, ObjKitT (use_op, reason, tool, Rest (options, state), tout))
            | Done base ->
              let xs =
                Nel.map_concat
                  (fun slice -> Nel.map (rest cx trace ~use_op reason options slice) x)
                  base
              in
              let t =
                match xs with
                | (x, []) -> x
                | (x0, x1 :: xs) -> UnionT (reason, UnionRep.make x0 x1 xs)
              in
              let use_op p = Frame (ReactGetConfig { polarity = p }, use_op) in
              (match options with
              | ReactConfigMerge Polarity.Neutral ->
                rec_unify cx trace ~use_op:(use_op Polarity.Neutral) t tout
              | ReactConfigMerge Polarity.Negative ->
                rec_flow_t cx trace ~use_op:(use_op Polarity.Negative) (tout, t)
              | ReactConfigMerge Polarity.Positive ->
                rec_flow_t cx trace ~use_op:(use_op Polarity.Positive) (t, tout)
              | _ ->
                (* Intentional UnknownUse here. *)
                rec_flow_t cx trace (t, tout)))
      in
      (********************)
      (* Object Read Only *)
      (********************)
      let object_read_only =
        let polarity = Polarity.Positive in
        let mk_read_only_object cx reason slice =
          let { Object.reason = r; props; dict; flags } = slice in
          let props = SMap.map (fun (t, _) -> Field (None, t, polarity)) props in
          let dict = Option.map dict (fun dict -> { dict with dict_polarity = polarity }) in
          let call = None in
          let id = Context.generate_property_map cx props in
          let proto = ObjProtoT reason in
          let t = mk_object_def_type ~reason:r ~flags ~dict ~call id proto in
          if flags.exact then
            ExactT (reason, t)
          else
            t
        in
        fun cx trace _ reason tout x ->
          let t =
            match Nel.map (mk_read_only_object cx reason) x with
            | (t, []) -> t
            | (t0, t1 :: ts) -> UnionT (reason, UnionRep.make t0 t1 ts)
          in
          (* Intentional UnknownUse here. *)
          rec_flow_t cx trace (t, tout)
      in
      (**************)
      (* Object Rep *)
      (**************)
      let object_rep =
        let mk_object cx reason { Object.reason = r; props; dict; flags } =
          (* TODO(jmbrown): Add polarity information to props *)
          let polarity = Polarity.Neutral in
          let props = SMap.map (fun (t, _) -> Field (None, t, polarity)) props in
          let dict = Option.map dict (fun dict -> { dict with dict_polarity = polarity }) in
          let call = None in
          let id = Context.generate_property_map cx props in
          let proto = ObjProtoT reason in
          let t = mk_object_def_type ~reason:r ~flags ~dict ~call id proto in
          if flags.exact then
            ExactT (reason, t)
          else
            t
        in
        fun cx trace use_op reason tout x ->
          let t =
            match Nel.map (mk_object cx reason) x with
            | (t, []) -> t
            | (t0, t1 :: ts) -> UnionT (reason, UnionRep.make t0 t1 ts)
          in
          rec_flow_t cx trace ~use_op (t, tout)
      in
      (****************)
      (* Object Widen *)
      (****************)
      let object_widen =
        let mk_object cx reason { Object.reason = r; props; dict; flags } =
          let polarity = Polarity.Neutral in
          let props = SMap.map (fun (t, _) -> Field (None, t, polarity)) props in
          let dict = Option.map dict (fun dict -> { dict with dict_polarity = polarity }) in
          let call = None in
          let id = Context.generate_property_map cx props in
          let proto = ObjProtoT reason in
          mk_object_def_type ~reason:r ~flags ~dict ~call id proto
        in
        let widen cx trace ~use_op ~obj_reason ~slice ~widened_id ~tout =
          let rec is_subset (x, y) =
            match (x, y) with
            | (UnionT (_, rep), u) ->
              UnionRep.members rep |> List.for_all (fun t -> is_subset (t, u))
            | (t, UnionT (_, rep)) ->
              UnionRep.members rep |> List.exists (fun u -> is_subset (t, u))
            | (MaybeT (_, t1), MaybeT (_, t2)) -> is_subset (t1, t2)
            | ( OptionalT { reason = _; type_ = t1; use_desc = _ },
                OptionalT { reason = _; type_ = t2; use_desc = _ } ) ->
              is_subset (t1, t2)
            | (DefT (_, _, (NullT | VoidT)), MaybeT _) -> true
            | (DefT (_, _, VoidT), OptionalT _) -> true
            | (t1, MaybeT (_, t2)) -> is_subset (t1, t2)
            | (t1, OptionalT { reason = _; type_ = t2; use_desc = _ }) -> is_subset (t1, t2)
            | (t1, t2) -> quick_subtype false t1 t2
          in
          let widen_type cx trace reason ~use_op t1 t2 =
            match (t1, t2) with
            | (t1, t2) when is_subset (t2, t1) -> (t1, false)
            | (OpenT _, t2) ->
              rec_flow_t cx trace ~use_op (t2, t1);
              (t1, false)
            | (t1, t2) ->
              ( Tvar.mk_where cx reason (fun t ->
                    rec_flow_t cx trace ~use_op (t1, t);
                    rec_flow_t cx trace ~use_op (t2, t)),
                true )
          in
          let widest = Context.spread_widened_types_get_widest cx widened_id in
          match widest with
          | None ->
            Context.spread_widened_types_add_widest cx widened_id slice;
            rec_flow_t cx trace ~use_op (mk_object cx obj_reason slice, tout)
          | Some widest ->
            let widest_pmap = widest.props in
            let new_pmap = slice.props in
            let pmap_and_changed =
              SMap.merge
                (fun propname p1 p2 ->
                  let p1 = get_prop widest.Object.reason p1 widest.Object.dict in
                  let p2 = get_prop slice.Object.reason p2 slice.Object.dict in
                  match (p1, p2) with
                  | (None, None) -> None
                  | (None, Some t) ->
                    let (t', opt, missing_prop) = type_optionality_and_missing_property t in
                    let t' =
                      if opt && not missing_prop then
                        optional t'
                      else
                        possibly_missing_prop propname widest.Object.reason t'
                    in
                    Some (t', true)
                  | (Some t, None) ->
                    let (t', opt, missing_prop) = type_optionality_and_missing_property t in
                    let t' =
                      if opt && not missing_prop then
                        optional t'
                      else
                        possibly_missing_prop propname slice.Object.reason t'
                    in
                    Some (t', not opt)
                  | (Some t1, Some t2) ->
                    let (t1', opt1, missing_prop1) = type_optionality_and_missing_property t1 in
                    let (t2', opt2, missing_prop2) = type_optionality_and_missing_property t2 in
                    let (t, changed) = widen_type cx trace obj_reason ~use_op t1' t2' in
                    if opt1 || opt2 then
                      Some
                        ( make_optional_with_possible_missing_props
                            propname
                            missing_prop1
                            missing_prop2
                            widest.Object.reason
                            t,
                          changed )
                    else
                      Some (t, changed))
                widest_pmap
                new_pmap
            in
            let (pmap', changed) =
              SMap.fold
                (fun k (t, changed) (acc_map, acc_changed) ->
                  (SMap.add k t acc_map, changed || acc_changed))
                pmap_and_changed
                (SMap.empty, false)
            in
            (* TODO: (jmbrown) we can be less strict here than unifying. It may be possible to
             * also merge the dictionary types *)
            let (dict, changed) =
              match (widest.dict, slice.dict) with
              | (Some d1, Some d2) ->
                rec_unify cx trace ~use_op d1.key d2.key;
                rec_unify cx trace ~use_op d1.value d2.value;
                (Some d1, changed)
              | (Some _, None) -> (None, true)
              | _ -> (None, changed)
            in
            let (exact, changed) =
              if widest.Object.flags.exact && not slice.Object.flags.exact then
                (false, true)
              else
                (widest.Object.flags.exact && slice.Object.flags.exact, changed)
            in
            if not changed then
              ()
            else
              let flags = { exact; frozen = false; sealed = Sealed } in
              let props = SMap.map (fun t -> (t, true)) pmap' in
              let slice' = { Object.reason = slice.Object.reason; props; flags; dict } in
              Context.spread_widened_types_add_widest cx widened_id slice';
              let obj = mk_object cx slice.Object.reason slice' in
              rec_flow_t cx trace ~use_op (obj, tout)
        in
        fun widened_id cx trace use_op reason tout x ->
          Nel.iter
            (fun slice -> widen cx trace ~use_op ~obj_reason:reason ~slice ~widened_id ~tout)
            x
      in
      (****************)
      (* React Config *)
      (****************)
      let react_config =
        Object.ReactConfig.(
          (* All props currently have a neutral polarity. However, they should have a
           * positive polarity (or even better, constant) since React.createElement()
           * freezes the type of props. We use a neutral polarity today because the
           * props type we flow the config into is written by users who very rarely
           * add a positive variance annotation. We may consider marking that type as
           * constant in the future as well. *)
          let prop_polarity = Polarity.Neutral in
          let finish cx trace reason config defaults children =
            let {
              Object.reason = config_reason;
              props = config_props;
              dict = config_dict;
              flags = config_flags;
            } =
              config
            in
            (* If we have some type for children then we want to add a children prop
             * to our config props. *)
            let config_props =
              Option.value_map children ~default:config_props ~f:(fun children ->
                  SMap.add "children" (children, true) config_props)
            in
            (* Remove the key and ref props from our config. We check key and ref
             * independently of our config. So we must remove them so the user can't
             * see them. *)
            let config_props = SMap.remove "key" config_props in
            let config_props = SMap.remove "ref" config_props in
            (* Create the final props map and dict.
             *
             * NOTE: React will copy any enumerable prop whether or not it
             * is own to the config. *)
            let (props, dict, flags) =
              match defaults with
              (* If we have some default props then we want to add the types for those
               * default props to our final props object. *)
              | Some
                  {
                    Object.reason = defaults_reason;
                    props = defaults_props;
                    dict = defaults_dict;
                    flags = defaults_flags;
                  } ->
                (* Merge our props and default props. *)
                let props =
                  SMap.merge
                    (fun _ p1 p2 ->
                      let p1 = get_prop config_reason p1 config_dict in
                      let p2 = get_prop defaults_reason p2 defaults_dict in
                      match (p1, p2) with
                      | (None, None) -> None
                      | (Some (t, _), None) -> Some (Field (None, t, prop_polarity))
                      | (None, Some (t, _)) -> Some (Field (None, t, prop_polarity))
                      (* If a property is defined in both objects, and the first property's
                       * type includes void then we want to replace every occurrence of void
                       * with the second property's type. This is consistent with the behavior
                       * of function default arguments. If you call a function, `f`, like:
                       * `f(undefined)` and there is a default value for the first argument,
                       * then we will ignore the void type and use the type for the default
                       * parameter instead. *)
                      | (Some (t1, _), Some (t2, _)) ->
                        (* Use CondT to replace void with t1. *)
                        let t =
                          Tvar.mk_where cx reason (fun tvar ->
                              rec_flow
                                cx
                                trace
                                ( filter_optional cx ~trace reason t1,
                                  CondT (reason, None, t2, tvar) ))
                        in
                        Some (Field (None, t, prop_polarity)))
                    config_props
                    defaults_props
                in
                (* Merge the dictionary from our config with the defaults dictionary. *)
                let dict =
                  Option.merge config_dict defaults_dict (fun d1 d2 ->
                      {
                        dict_name = None;
                        key = UnionT (reason, UnionRep.make d1.key d2.key []);
                        value =
                          UnionT
                            ( reason,
                              UnionRep.make
                                (read_dict config_reason d1)
                                (read_dict defaults_reason d2)
                                [] );
                        dict_polarity = prop_polarity;
                      })
                in
                (* React freezes the config so we set the frozen flag to true. The
                 * final object is only exact if both the config and defaults objects
                 * are exact. *)
                let flags =
                  {
                    frozen = true;
                    sealed = Sealed;
                    exact =
                      config_flags.exact
                      && defaults_flags.exact
                      && Obj_type.sealed_in_op reason config_flags.sealed
                      && Obj_type.sealed_in_op reason defaults_flags.sealed;
                  }
                in
                (props, dict, flags)
              (* Otherwise turn our slice props map into an object props. *)
              | None ->
                (* All of the fields are read-only so we create positive fields. *)
                let props = SMap.map (fun (t, _) -> Field (None, t, prop_polarity)) config_props in
                (* Create a new dictionary from our config's dictionary with a
                 * positive polarity. *)
                let dict =
                  Option.map config_dict (fun d ->
                      {
                        dict_name = None;
                        key = d.key;
                        value = d.value;
                        dict_polarity = prop_polarity;
                      })
                in
                (* React freezes the config so we set the frozen flag to true. The
                 * final object is only exact if the config object is exact. *)
                let flags =
                  {
                    frozen = true;
                    sealed = Sealed;
                    exact = config_flags.exact && Obj_type.sealed_in_op reason config_flags.sealed;
                  }
                in
                (props, dict, flags)
            in
            let call = None in
            (* Finish creating our props object. *)
            let id = Context.generate_property_map cx props in
            let proto = ObjProtoT reason in
            let t =
              DefT (reason, bogus_trust (), ObjT (mk_objecttype ~flags ~dict ~call id proto))
            in
            if flags.exact then
              ExactT (reason, t)
            else
              t
          in
          fun state cx trace use_op reason tout x ->
            match state with
            (* If we have some type for default props then we need to wait for that
             * type to resolve before finishing our props type. *)
            | Config { defaults = Some t; children } ->
              let tool = Resolve Next in
              let state = Defaults { config = x; children } in
              rec_flow cx trace (t, ObjKitT (use_op, reason, tool, ReactConfig state, tout))
            (* If we have no default props then finish our object and flow it to our
             * tout type. *)
            | Config { defaults = None; children } ->
              let ts = Nel.map (fun x -> finish cx trace reason x None children) x in
              let t =
                match ts with
                | (t, []) -> t
                | (t0, t1 :: ts) -> UnionT (reason, UnionRep.make t0 t1 ts)
              in
              rec_flow cx trace (t, UseT (use_op, tout))
            (* If we had default props and those defaults resolved then finish our
             * props object with those default props. *)
            | Defaults { config; children } ->
              let ts =
                Nel.map_concat
                  (fun c -> Nel.map (fun d -> finish cx trace reason c (Some d) children) x)
                  config
              in
              let t =
                match ts with
                | (t, []) -> t
                | (t0, t1 :: ts) -> UnionT (reason, UnionRep.make t0 t1 ts)
              in
              rec_flow cx trace (t, UseT (use_op, tout)))
      in
      (*********************)
      (* Object Resolution *)
      (*********************)
      let next = function
        | Spread (options, state) -> object_spread options state
        | Rest (options, state) -> object_rest options state
        | ReactConfig state -> react_config state
        | ReadOnly -> object_read_only
        | ObjectRep -> object_rep
        | ObjectWiden id -> object_widen id
      in
      (* Intersect two object slices: slice * slice -> slice
       *
       * In general it is unsound to combine intersection types, but since object
       * kit utilities never write to their arguments, it is safe in this specific
       * case.
       *
       * {...{p:T}&{q:U}} = {...{p:T,q:U}}
       * {...{p:T}&{p:U}} = {...{p:T&U}}
       * {...A&(B|C)} = {...(A&B)|(A&C)}
       * {...(A|B)&C} = {...(A&C)|(B&C)}
       *)
      let intersect2
          reason
          { Object.reason = r1; props = props1; dict = dict1; flags = flags1 }
          { Object.reason = r2; props = props2; dict = dict2; flags = flags2 } =
        let intersection t1 t2 = IntersectionT (reason, InterRep.make t1 t2 []) in
        let merge_props (t1, own1) (t2, own2) =
          let (t1, t2, opt) =
            match (t1, t2) with
            | ( OptionalT { reason = _; type_ = t1; use_desc = _ },
                OptionalT { reason = _; type_ = t2; use_desc = _ } ) ->
              (t1, t2, true)
            | (OptionalT { reason = _; type_ = t1; use_desc = _ }, t2)
            | (t1, OptionalT { reason = _; type_ = t2; use_desc = _ })
            | (t1, t2) ->
              (t1, t2, false)
          in
          let t = intersection t1 t2 in
          let t =
            if opt then
              optional t
            else
              t
          in
          (t, own1 || own2)
        in
        let props =
          SMap.merge
            (fun _ p1 p2 ->
              let read_dict r d = (optional (read_dict r d), true) in
              match (p1, p2) with
              | (None, None) -> None
              | (Some p1, Some p2) -> Some (merge_props p1 p2)
              | (Some p1, None) ->
                (match dict2 with
                | Some d2 -> Some (merge_props p1 (read_dict r2 d2))
                | None -> Some p1)
              | (None, Some p2) ->
                (match dict1 with
                | Some d1 -> Some (merge_props (read_dict r1 d1) p2)
                | None -> Some p2))
            props1
            props2
        in
        let dict =
          Option.merge dict1 dict2 (fun d1 d2 ->
              {
                dict_name = None;
                key = intersection d1.key d2.key;
                value = intersection (read_dict r1 d1) (read_dict r2 d2);
                dict_polarity = Polarity.Neutral;
              })
        in
        let flags =
          {
            frozen = flags1.frozen || flags2.frozen;
            sealed = Sealed;
            exact = flags1.exact || flags2.exact;
          }
        in
        (props, dict, flags)
      in
      let intersect2_with_reason reason intersection_loc x1 x2 =
        let (props, dict, flags) = intersect2 reason x1 x2 in
        let reason = mk_reason RObjectType intersection_loc in
        Object.{ reason; props; dict; flags }
      in
      let resolved cx trace use_op reason resolve_tool tool tout x =
        match resolve_tool with
        | Next -> next tool cx trace use_op reason tout x
        | List0 ((t, todo), join) ->
          let resolve_tool = Resolve (List (todo, Nel.one x, join)) in
          rec_flow cx trace (t, ObjKitT (use_op, reason, resolve_tool, tool, tout))
        | List (todo, done_rev, join) ->
          (match todo with
          | [] ->
            let x =
              match join with
              | (_, Or) -> Nel.cons x done_rev |> Nel.concat
              | (loc, And) -> merge (intersect2_with_reason reason loc) x done_rev
            in
            next tool cx trace use_op reason tout x
          | t :: todo ->
            let done_rev = Nel.cons x done_rev in
            let resolve_tool = Resolve (List (todo, done_rev, join)) in
            rec_flow cx trace (t, ObjKitT (use_op, reason, resolve_tool, tool, tout)))
      in
      let object_slice cx r id dict flags =
        let props = Context.find_props cx id in
        let props = SMap.mapi (read_prop r flags) props in
        let dict =
          Option.map dict (fun d ->
              {
                dict_name = None;
                key = d.key;
                value = read_dict r d;
                dict_polarity = Polarity.Neutral;
              })
        in
        { Object.reason = r; props; dict; flags }
      in
      let interface_slice cx r id =
        let flags = { frozen = false; exact = false; sealed = Sealed } in
        let (id, dict) =
          let props = Context.find_props cx id in
          match (SMap.get "$key" props, SMap.get "$value" props) with
          | (Some (Field (_, key, polarity)), Some (Field (_, value, polarity')))
            when polarity = polarity' ->
            let props = props |> SMap.remove "$key" |> SMap.remove "$value" in
            let id = Context.generate_property_map cx props in
            let dict = { dict_name = None; key; value; dict_polarity = polarity } in
            (id, Some dict)
          | _ -> (id, None)
        in
        object_slice cx r id dict flags
      in
      let resolve cx trace use_op reason resolve_tool tool tout = function
        (* We extract the props from an ObjT. *)
        | DefT (r, _, ObjT { props_tmap; dict_t; Type.flags; _ }) ->
          let x = Nel.one (object_slice cx r props_tmap dict_t flags) in
          resolved cx trace use_op reason resolve_tool tool tout x
        (* We take the fields from an InstanceT excluding methods (because methods
         * are always on the prototype). We also want to resolve fields from the
         * InstanceT's super class so we recurse. *)
        | DefT (r, _, InstanceT (_, super, _, { own_props; inst_kind; _ })) ->
          let resolve_tool = Super (interface_slice cx r own_props, resolve_tool) in
          begin
            match (tool, inst_kind) with
            | (Spread _, InterfaceKind _)
            | (ObjectWiden _, InterfaceKind _) ->
              add_output
                cx
                ~trace
                (Error_message.ECannotSpreadInterface
                   { spread_reason = reason; interface_reason = r });
              rec_flow cx trace (AnyT.why AnyError reason, UseT (use_op, tout))
            | _ -> rec_flow cx trace (super, ObjKitT (use_op, reason, resolve_tool, tool, tout))
          end
        (* Statics of a class. TODO: This logic is unfortunately duplicated from the
         * top-level pattern matching against class lower bounds to object-like
         * uses. This duplication should be removed. *)
        | DefT (r, _, ClassT i) ->
          let t = Tvar.mk cx r in
          rec_flow cx trace (i, GetStaticsT (r, t));
          rec_flow cx trace (t, ObjKitT (use_op, reason, Resolve resolve_tool, tool, tout))
        (* Resolve each member of a union. *)
        | UnionT (union_reason, rep) ->
          let union_loc = aloc_of_reason union_reason in
          let (t, todo) = UnionRep.members_nel rep in
          let resolve_tool = Resolve (List0 (todo, (union_loc, Or))) in
          let tool =
            match tool with
            | Spread (options, state) ->
              Spread (options, { state with Spread.union_reason = Some union_reason })
            | _ -> tool
          in
          rec_flow cx trace (t, ObjKitT (use_op, reason, resolve_tool, tool, tout))
        (* Resolve each member of an intersection. *)
        | IntersectionT (intersection_reason, rep) ->
          let intersection_loc = aloc_of_reason intersection_reason in
          let (t, todo) = InterRep.members_nel rep in
          let resolve_tool = Resolve (List0 (todo, (intersection_loc, And))) in
          rec_flow cx trace (t, ObjKitT (use_op, reason, resolve_tool, tool, tout))
        (* Mirroring Object.assign() and {...null} semantics, treat null/void as
         * empty objects. *)
        | DefT (_, _, (NullT | VoidT)) ->
          let flags = { frozen = true; sealed = Sealed; exact = true } in
          let x = Nel.one { Object.reason; props = SMap.empty; dict = None; flags } in
          resolved cx trace use_op reason resolve_tool tool tout x
        (* TODO(jmbrown): Investigate if these cases can be used for ReactConfig/ObjecRep/Rest.
         * In principle, we should be able to use it for Rest, but right now
         * `const {x, ...y} = 3;` tries to get `x` from Number.
         * They don't make sense with $ReadOnly's semantics, since $ReadOnly doesn't model
         * copying/spreading an object. *)
        | DefT (_, _, (StrT _ | NumT _ | BoolT _))
          when match tool with
               | ObjectWiden _
               | Spread _ ->
                 true
               | _ -> false ->
          let flags = { frozen = true; sealed = Sealed; exact = true } in
          let x = Nel.one { Object.reason; props = SMap.empty; dict = None; flags } in
          resolved cx trace use_op reason resolve_tool tool tout x
        (* mixed is treated as {[string]: mixed} except in type spread, where it's treated as
         * {}. Any JavaScript value may be treated as an object and so this is safe.
         *
         * We ought to use {} for everything since it is a more sound representation
         * of `mixed` as an object.
         *)
        | DefT (r, _, MixedT _) as t ->
          let flags = { frozen = true; sealed = Sealed; exact = true } in
          let x =
            match tool with
            | ObjectWiden _
            | Spread _ ->
              Nel.one { Object.reason; props = SMap.empty; dict = None; flags }
            | _ ->
              Nel.one
                {
                  Object.reason;
                  props = SMap.empty;
                  dict =
                    Some
                      {
                        dict_name = None;
                        key = StrT.make r |> with_trust bogus_trust;
                        value = t;
                        dict_polarity = Polarity.Neutral;
                      };
                  flags;
                }
          in
          resolved cx trace use_op reason resolve_tool tool tout x
        (* If we see an empty then propagate empty to tout. *)
        | DefT (r, trust, EmptyT _) -> rec_flow cx trace (EmptyT.make r trust, UseT (use_op, tout))
        (* Propagate any. *)
        | AnyT (_, src) -> rec_flow cx trace (AnyT.why src reason, UseT (use_op, tout))
        (* Other types have reasonable object representations that may be added as
         * new uses of the object kit resolution code is found. *)
        | t ->
          add_output
            cx
            ~trace
            (Error_message.EInvalidObjectKit { reason = reason_of_t t; reason_op = reason; use_op })
      in
      let super cx trace use_op reason resolve_tool tool tout acc = function
        | DefT (r, _, InstanceT (_, super, _, { own_props; _ })) ->
          let slice = interface_slice cx r own_props in
          let acc = intersect2 reason acc slice in
          let acc =
            let (props, dict, flags) = acc in
            { Object.reason; props; dict; flags }
          in
          let resolve_tool = Super (acc, resolve_tool) in
          rec_flow cx trace (super, ObjKitT (use_op, reason, resolve_tool, tool, tout))
        | AnyT _ -> rec_flow cx trace (AnyT.untyped reason, UseT (use_op, tout))
        | _ -> next tool cx trace use_op reason tout (Nel.one acc)
      in
      fun cx trace ~use_op reason resolve_tool tool tout l ->
        match resolve_tool with
        | Resolve resolve_tool -> resolve cx trace use_op reason resolve_tool tool tout l
        | Super (acc, resolve_tool) -> super cx trace use_op reason resolve_tool tool tout acc l)
end

open Pattern

type error =
  | ReplacementNotUsed of pattern
  | EmptyMeetOrInverseJoin of pattern
[@@deriving show]

exception EmptyMeet

module M = Map.Make (struct type t = path let compare = compare end)

let singleton path export = `Matched (M.singleton path export)

let join2 r1 r2 =
  match r1, r2 with
  | _, `NoMatch -> r1
  | `NoMatch, _ -> r2
  | `Matched m1, `Matched m2 ->
    let merger _ e1 e2 =
      match e1, e2 with
      | `Public, _ | _, `Public -> Some `Public
      | `Private, `Private -> Some `Private
    in `Matched (M.union merger m1 m2)

let join rs = List.fold_left join2 `NoMatch rs

let meet2 r1 r2 =
  match r1, r2 with
  | _, `NoMatch | `NoMatch, _ -> `NoMatch
  | `Matched m1, `Matched m2 ->
    let merger _ e1 e2 =
      match e1, e2 with
      | None, _ | _, None -> None
      | Some `Private, _ | _, Some `Private -> Some `Private
      | Some `Public, Some `Public -> Some `Public
    in `Matched (M.merge merger m1 m2)

let meet =
  function
  | [] -> raise EmptyMeet
  | r :: rs -> List.fold_left meet2 r rs

type mode = [`Normal | `Inverse]

let flip_mode : mode -> mode =
  function
  | `Normal -> `Inverse
  | `Inverse -> `Normal

let rec trim_prefix prefix path =
  match prefix, path with
  | [], _ -> Some path
  | _, [] -> None
  | (id :: prefix), (id' :: path) ->
    if id = id' then trim_prefix prefix path else None

type modal_result = [ `NoMatch | `Matched of exportability M.t ]

let rec modal_run ~mode ~export pattern path : (modal_result, error) result =
  match mode, pattern, path with
  | `Normal, PatWildcard, [] -> Ok `NoMatch
  | `Inverse, PatWildcard, [] -> Ok (singleton [] export)
  | `Normal, PatWildcard, (_ :: _) -> Ok (singleton path export)
  | `Inverse, PatWildcard, (_ :: _) -> Ok `NoMatch
  | `Inverse, PatScope (_, Some _, _), _ ->
    Error (ReplacementNotUsed pattern)
  | _, PatScope (prefix, prefix_replacement, pattern), _ ->
    begin
      match trim_prefix prefix path with
      | None ->
        begin
          match mode with
          | `Normal -> Ok `NoMatch
          | `Inverse -> Ok (singleton path export)
        end
      | Some remaining ->
        let prefix_replacement = Option.value prefix_replacement ~default:prefix in
        modal_run ~mode ~export pattern remaining |> Result.map begin
          function
          | `NoMatch -> `NoMatch
          | `Matched m ->
            `Matched (m |> M.to_seq |> Seq.map (fun (r, export) -> prefix_replacement @ r, export) |> M.of_seq)
        end
    end
  | `Normal, PatId (prefix, prefix_replacement), _ ->
    let prefix_replacement = Option.value prefix_replacement ~default:prefix in
    begin
      match trim_prefix prefix path with
      | None -> Ok `NoMatch
      | Some remaining -> Ok (singleton (prefix_replacement @ remaining) export)
    end
  | `Inverse, PatId (_, Some _), _ ->
    Error (ReplacementNotUsed pattern)
  | `Inverse, PatId (prefix, None), _ ->
    begin
      match trim_prefix prefix path with
      | None -> Ok (singleton path export)
      | Some _ -> Ok `NoMatch
    end
  | `Normal, PatSeq pats, _ ->
    let f r pat = Result.bind r @@
      function
      | `NoMatch -> modal_run ~mode ~export pat path
      | `Matched m ->
        Result.map join begin
          M.bindings m |> ResultMonad.map @@ fun (path, export) ->
          modal_run ~mode ~export pat path
        end
    in
    List.fold_left f (Ok `NoMatch) pats
  | `Inverse, PatSeq pats, _ ->
    let f r pat = Result.bind r @@
      function
      | `NoMatch -> Ok `NoMatch
      | `Matched m ->
        Result.map join begin
          M.bindings m |> ResultMonad.map @@ fun (path, export) ->
          modal_run ~mode ~export pat path
        end
    in
    List.fold_left f (Ok (singleton path export)) pats
  | _, PatInv pat, _ -> modal_run ~mode:(flip_mode mode) ~export pat path
  | _, PatExport (export, pat), _ -> modal_run ~mode ~export pat path
  | `Normal, PatJoin pats, _ | `Inverse, PatMeet pats, _ ->
    Result.map join begin
      pats |> ResultMonad.map @@ fun pat -> modal_run ~mode ~export pat path
    end
  | `Normal, PatMeet [], _ | `Inverse, PatJoin [], _ ->
    Error (EmptyMeetOrInverseJoin pattern)
  | `Normal, PatMeet pats, _ | `Inverse, PatJoin pats, _ ->
    Result.map meet begin
      pats |> ResultMonad.map @@ fun pat -> modal_run ~mode ~export pat path
    end

type result_ = [ `NoMatch | `Matched of (path * exportability) list ]
[@@deriving show]

let pp_result = Format.pp_print_result ~ok:pp_result_ ~error:pp_error

let run export pattern path : (result_, error) result =
  modal_run ~mode:`Normal ~export pattern path |> Result.map @@
  function
  | `NoMatch -> `NoMatch
  | `Matched m -> `Matched (M.bindings m)

let rec modal_check ~mode pattern : (unit, error) result =
  match mode, pattern with
  | _, PatWildcard -> Ok ()
  | `Inverse, PatId (_, Some _) -> Error (ReplacementNotUsed pattern)
  | _, PatId _ -> Ok ()
  | `Inverse, PatScope (_, Some _, _) -> Error (ReplacementNotUsed pattern)
  | _, PatScope (_, _, pattern) -> modal_check ~mode pattern
  | _, PatSeq pats -> ResultMonad.iter (modal_check ~mode) pats
  | _, PatInv pattern -> modal_check ~mode:(flip_mode mode) pattern
  | _, PatExport (_, pattern) -> modal_check ~mode pattern
  | `Normal, PatMeet [] | `Inverse, PatJoin [] ->
    Error (EmptyMeetOrInverseJoin pattern)
  | _, PatJoin pats | _, PatMeet pats ->
    ResultMonad.iter (modal_check ~mode) pats

let check pattern : (unit, error) result =
  modal_check ~mode:`Normal pattern

let pp_check_result = Format.pp_print_result ~ok:(fun fmt () -> Format.pp_print_string fmt "()") ~error:pp_error

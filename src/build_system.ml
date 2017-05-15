open Import
open Future

module Pset  = Path.Set
module Pmap  = Path.Map

module Exec_status = struct
  module Starting = struct
    type t = { for_file : Path.t }
  end
  module Running = struct
    type t = { for_file : Path.t; future : unit Future.t }
  end
  type t =
    | Not_started of (targeting:Path.t -> unit Future.t)
    | Starting of Starting.t
    | Running  of Running.t
end

module Rule = struct
  type t =
    { targets        : Pset.t
    ; build          : Action.t Build.t
    ; mutable exec   : Exec_status.t
    }
end

type t =
  { (* File specification by targets *)
    files      : (Path.t, Rule.t) Hashtbl.t
  ; contexts   : Context.t list
  ; (* Table from target to digest of [(deps, targets, action)] *)
    trace      : (Path.t, Digest.t) Hashtbl.t
  ; timestamps : (Path.t, float) Hashtbl.t
  ; mutable local_mkdirs : Path.Local.Set.t
  ; all_targets_by_dir : Pset.t Pmap.t Lazy.t
  }

let all_targets t = Hashtbl.fold t.files ~init:[] ~f:(fun ~key ~data:_ acc -> key :: acc)

let timestamp t fn =
  match Hashtbl.find t.timestamps fn with
  | Some _ as x -> x
  | None ->
    match Unix.lstat (Path.to_string fn) with
    | exception _ -> None
    | stat        ->
      let ts = stat.st_mtime in
      Hashtbl.add t.timestamps ~key:fn ~data:ts;
      Some ts

type limit_timestamp =
  { missing_files : bool
  ; limit         : float option
  }

let sexp_of_limit_timestamp lt =
  Sexp.To_sexp.(record
                  [ "missing_files" , bool lt.missing_files
                  ; "limit"         , option float lt.limit
                  ])

let merge_timestamp t fns ~merge =
  let init =
    { missing_files = false
    ; limit         = None
    }
  in
  List.fold_left fns ~init
    ~f:(fun acc fn ->
      match timestamp t fn with
      | None    -> { acc with missing_files = true }
      | Some ts ->
        { acc with
          limit =
            match acc.limit with
            | None -> Some ts
            | Some ts' -> Some (merge ts ts')
        })

let min_timestamp t fns = merge_timestamp t fns ~merge:min
let max_timestamp t fns = merge_timestamp t fns ~merge:max

let find_file_exn t file =
  Hashtbl.find_exn t.files file ~string_of_key:(fun fn -> sprintf "%S" (Path.to_string fn))
    ~table_desc:(fun _ -> "<target to rule>")

let is_target t file = Hashtbl.mem t.files file

module Build_error = struct
  type t =
    { backtrace : Printexc.raw_backtrace
    ; dep_path  : Path.t list
    ; exn       : exn
    }

  let backtrace t = t.backtrace
  let dependency_path t = t.dep_path
  let exn t = t.exn

  exception E of t

  let raise t ~targeting ~backtrace exn =
    let rec build_path acc targeting ~seen =
      assert (not (Pset.mem targeting seen));
      let seen = Pset.add targeting seen in
      let rule = find_file_exn t targeting in
      match rule.exec with
      | Not_started _ -> assert false
      | Running { for_file; _ } | Starting { for_file } ->
        if for_file = targeting then
          acc
        else
          build_path (for_file :: acc) for_file ~seen
    in
    let dep_path = build_path [targeting] targeting ~seen:Pset.empty in
    raise (E { backtrace; dep_path; exn })
end

let wait_for_file t fn ~targeting =
  match Hashtbl.find t.files fn with
  | None ->
    if Path.is_in_build_dir fn then
      die "no rule found for %s" (Utils.describe_target fn)
    else if Path.exists fn then
      return ()
    else
      die "file unavailable: %s" (Path.to_string fn)
  | Some rule ->
    match rule.exec with
    | Not_started f ->
      rule.exec <- Starting { for_file = targeting };
      let future =
        with_exn_handler (fun () -> f ~targeting:fn)
          ~handler:(fun exn backtrace ->
              match exn with
              | Build_error.E _ -> reraise exn
              | exn -> Build_error.raise t exn ~targeting:fn ~backtrace)
      in
      rule.exec <- Running { for_file = targeting; future };
      future
    | Running { future; _ } -> future
    | Starting _ ->
      (* Recursive deps! *)
      let rec build_loop acc targeting =
        let acc = targeting :: acc in
        if fn = targeting then
          acc
        else
          let rule = find_file_exn t targeting in
          match rule.exec with
          | Not_started _ | Running _ -> assert false
          | Starting { for_file } ->
            build_loop acc for_file
      in
      let loop = build_loop [fn] targeting in
      die "Dependency cycle between the following files:\n    %s"
        (String.concat ~sep:"\n--> "
           (List.map loop ~f:Path.to_string))

module Build_exec = struct
  open Build.Primitive
  open Build.Repr

  let exec bs t ~targeting =
    let deps = ref Pset.empty in
    let wait_for_deps = ref Future.unit in
    let rec exec : type a. a t -> a Future.t = fun t ->
      match t with
      | Return x -> Future.return x
      | Bind (t, f) -> exec t >>= fun x -> exec (f x)
      | Map  (t, f) -> exec t >>| fun x -> f x
      | Both (t1, t2) -> Future.both (exec t1) (exec t2)
      | Contents path ->
        wait_for_file bs path ~targeting >>| fun () ->
        Build.Read_result.Ok (read_file (Path.to_string path))
      | Lines_of path ->
        wait_for_file bs path ~targeting >>| fun () ->
        Build.Read_result.Ok (lines_of_file (Path.to_string path))
      | Fail fail -> fail.fail ()
      | Memo m -> begin
          match m.state with
          | Evaluated x -> return x
          | Evaluating ->
            die "Dependency cycle evaluating memoized build arrow %s" m.name
          | Unevaluated ->
            m.state <- Evaluating;
            exec m.t >>| fun x ->
            m.state <- Evaluated x;
            x
        end
      | Prim prim ->
        match prim with
        | Paths paths ->
          let new_deps = Pset.diff paths !deps in
          deps := Pset.union new_deps !deps;
          wait_for_deps :=
            Pset.fold new_deps ~init:!wait_for_deps ~f:(fun fn acc ->
              let future = wait_for_file bs fn ~targeting in
              acc >>= fun () -> future);
          Future.unit
        | Glob (dir, re) ->
          return
            (match Pmap.find dir (Lazy.force bs.all_targets_by_dir) with
             | None -> Pset.empty
             | Some targets ->
               Pset.filter targets ~f:(fun path ->
                 Re.execp re (Path.basename path)))
        | File_exists p ->
          let dir = Path.parent p in
          let targets =
            Option.value (Pmap.find dir (Lazy.force bs.all_targets_by_dir))
              ~default:Pset.empty
          in
          return (Pset.mem p targets)
        | Record_lib_deps _ -> return ()
    in
    exec (Build.repr t) >>= fun action ->
    !wait_for_deps >>| fun () ->
    (!deps, action)
end

let add_rule t fn rule ~allow_override =
  if not allow_override && Hashtbl.mem t.files fn then
    die "multiple rules generated for %s" (Path.to_string fn);
  Hashtbl.add t.files ~key:fn ~data:rule

let create_file_rules t targets rule ~allow_override =
  Pset.iter targets ~f:(fun fn -> add_rule t fn rule ~allow_override)

module Pre_rule = Build.Rule

let refresh_targets_timestamps_after_rule_execution t targets =
  let missing =
    List.fold_left targets ~init:Pset.empty ~f:(fun acc fn ->
      match Unix.lstat (Path.to_string fn) with
      | exception _ -> Pset.add fn acc
      | stat ->
        let ts = stat.st_mtime in
        Hashtbl.replace t.timestamps ~key:fn ~data:ts;
        acc)
  in
  if not (Pset.is_empty missing) then
    die "@{<error>Error@}: Rule failed to generate the following targets:\n%s"
      (Pset.elements missing
       |> List.map ~f:(fun fn -> sprintf "- %s" (Path.to_string fn))
       |> String.concat ~sep:"\n")

(* This contains the targets of the actions that are being executed. On exit, we need to
   delete them as they might contain garbage *)
let pending_targets = ref Pset.empty

let () =
  Future.Scheduler.at_exit_after_waiting_for_commands (fun () ->
    let fns = !pending_targets in
    pending_targets := Pset.empty;
    Pset.iter fns ~f:Path.unlink_no_err)

let make_local_dir t path =
  match Path.kind path with
  | Local path ->
    if not (Path.Local.Set.mem path t.local_mkdirs) then begin
      Path.Local.mkdir_p path;
      t.local_mkdirs <- Path.Local.Set.add path t.local_mkdirs
    end
  | _ -> ()

let make_local_parent_dirs t paths ~map_path =
  Pset.iter paths ~f:(fun path ->
    match Path.kind (map_path path) with
    | Local path when not (Path.Local.is_root path) ->
      let parent = Path.Local.parent path in
      if not (Path.Local.Set.mem parent t.local_mkdirs) then begin
        Path.Local.mkdir_p parent;
        t.local_mkdirs <- Path.Local.Set.add parent t.local_mkdirs
      end
    | _ -> ())

let sandbox_dir = Path.of_string "_build/.sandbox"

let compile_rule t ?(allow_override=false) pre_rule =
  let { Pre_rule. build; targets; sandbox } = pre_rule in

  (*
  if !Clflags.debug_rules then begin
    let deps, lib_deps = Approx_deps.collect t ~all_targets_by_dir in
    let f set =
      Pset.elements set
      |> List.map ~f:Path.to_string
      |> String.concat ~sep:", "
    in
    let deps = Pset.union rule_deps static_deps in
    let lib_deps = Build_interpret.lib_deps build in
    if Pmap.is_empty lib_deps then
      Printf.eprintf "{%s} -> {%s}\n" (f deps) (f targets)
    else
      let lib_deps =
        Pmap.fold lib_deps ~init:String_map.empty ~f:(fun ~key:_ ~data acc ->
          Build.merge_lib_deps acc data)
        |> String_map.bindings
        |> List.map ~f:(fun (name, kind) ->
          match (kind : Build.lib_dep_kind) with
          | Required -> name
          | Optional -> sprintf "%s (optional)" name)
        |> String.concat ~sep:", "
      in
      Printf.eprintf "{%s}, libs:{%s} -> {%s}\n" (f deps) lib_deps (f targets)
  end;
  *)

  let exec = Exec_status.Not_started (fun ~targeting ->
    make_local_parent_dirs t targets ~map_path:(fun x -> x);
    Build_exec.exec t build ~targeting
    >>= fun (deps, action) ->
    if !Clflags.debug_actions then
      Format.eprintf "@{<debug>Action@}: %s@."
        (Sexp.to_string (Action.sexp_of_t action));
    let deps_as_list    = Pset.elements deps    in
    let targets_as_list = Pset.elements targets in
    let hash =
      let trace = (deps_as_list, targets_as_list, Action.for_hash action) in
      Digest.string (Marshal.to_string trace [])
    in
    let sandbox_dir =
      if sandbox then
        Some (Path.relative sandbox_dir (Digest.to_hex hash))
      else
        None
    in
    let rule_changed =
      List.fold_left targets_as_list ~init:false ~f:(fun acc fn ->
        match Hashtbl.find t.trace fn with
        | None ->
          Hashtbl.add t.trace ~key:fn ~data:hash;
          true
        | Some prev_hash ->
          Hashtbl.replace t.trace ~key:fn ~data:hash;
          acc || prev_hash <> hash)
    in
    let targets_min_ts = min_timestamp t targets_as_list in
    let deps_max_ts    = max_timestamp t deps_as_list    in
    if rule_changed ||
       match deps_max_ts, targets_min_ts with
       | _, { missing_files = true; _ } ->
         (* Missing targets -> rebuild *)
         true
       | _, { missing_files = false; limit = None } ->
         (* CR-someday jdimino: no target, this should be a user error *)
         true
       | { missing_files = true; _ }, _ ->
         Sexp.code_error
           "Dependencies missing after waiting for them"
           [ "deps", Sexp.To_sexp.list Path.sexp_of_t deps_as_list ]
       | { limit = None; missing_files = false },
         { missing_files = false; _ } ->
         (* No dependencies, no need to do anything if the rule hasn't changed and targets
            are here. *)
         false
       | { limit = Some deps_max; missing_files = false },
         { limit = Some targets_min; missing_files = false } ->
         targets_min < deps_max
    then (
      if !Clflags.debug_actions then
        Format.eprintf "@{<debug>Action@}: -> running action@.";
      (* Do not remove files that are just updated, otherwise this would break incremental
         compilation *)
      let targets_to_remove =
        Pset.diff targets (Action.Mini_shexp.updated_files action.action)
      in
      Pset.iter targets_to_remove ~f:Path.unlink_no_err;
      pending_targets := Pset.union targets_to_remove !pending_targets;
      let action =
        match sandbox_dir with
        | Some sandbox_dir ->
          Path.rm_rf sandbox_dir;
          let sandboxed path =
            if Path.is_local path then
              Path.append sandbox_dir path
            else
              path
          in
          make_local_parent_dirs t deps    ~map_path:sandboxed;
          make_local_parent_dirs t targets ~map_path:sandboxed;
          Action.sandbox action
            ~sandboxed
            ~deps:deps_as_list
            ~targets:targets_as_list
        | None ->
          action
      in
      make_local_dir t action.dir;
      Action.exec ~targets action >>| fun () ->
      Option.iter sandbox_dir ~f:Path.rm_rf;
      (* All went well, these targets are no longer pending *)
      pending_targets := Pset.diff !pending_targets targets_to_remove;
      refresh_targets_timestamps_after_rule_execution t targets_as_list
    ) else (
      if !Clflags.debug_actions then
        Format.eprintf
          "@{<debug>Action@}: -> not running action as targets are up-to-date@\n\
           @{<debug>Action@}: -> @[%a@]@."
          Sexp.pp
          (Sexp.To_sexp.(record
                           [ "rule_changed"   , bool rule_changed
                           ; "targets_min_ts" , sexp_of_limit_timestamp targets_min_ts
                           ; "deps_max_ts"    , sexp_of_limit_timestamp deps_max_ts
                           ]));
      return ()
    )
  ) in
  let rule =
    { Rule.
      targets = targets
    ; build
    ; exec
    }
  in
  create_file_rules t targets rule ~allow_override

let setup_copy_rules t ~all_non_target_source_files =
  List.iter t.contexts ~f:(fun (ctx : Context.t) ->
    let ctx_dir = ctx.build_dir in
    Pset.iter all_non_target_source_files ~f:(fun path ->
      let ctx_path = Path.append ctx_dir path in
      if is_target t ctx_path &&
         String.is_suffix (Path.basename ctx_path) ~suffix:".install" then
        (* Do not copy over .install files that are generated by a rule. *)
        ()
      else
        let build = Build.copy ~src:path ~dst:ctx_path in
        (* We temporarily allow overrides while setting up copy rules
           from the source directory so that artifact that are already
           present in the source directory are not re-computed.

           This allows to keep generated files in tarballs. Maybe we
           should allow it on a case-by-case basis though.  *)
        compile_rule t (Pre_rule.make build ~targets:[ctx_path])
          ~allow_override:true))

module Trace = struct
  type t = (Path.t, Digest.t) Hashtbl.t

  let file = "_build/.db"

  let dump (trace : t) =
    let sexp =
      Sexp.List (
        Hashtbl.fold trace ~init:Pmap.empty ~f:(fun ~key ~data acc ->
          Pmap.add acc ~key ~data)
        |> Path.Map.bindings
        |> List.map ~f:(fun (path, hash) ->
          Sexp.List [ Atom (Path.to_string path); Atom (Digest.to_hex hash) ]))
    in
    if Sys.file_exists "_build" then
      write_file file (Sexp.to_string sexp)

  let load () =
    let trace = Hashtbl.create 1024 in
    if Sys.file_exists file then begin
      let sexp = Sexp_load.single file in
      let bindings =
        let open Sexp.Of_sexp in
        list (pair Path.t (fun s -> Digest.from_hex (string s))) sexp
      in
      List.iter bindings ~f:(fun (path, hash) ->
        Hashtbl.add trace ~key:path ~data:hash);
    end;
    trace
end

let create ~contexts ~file_tree ~rules =
  let all_source_files =
    File_tree.fold file_tree ~init:Pset.empty ~f:(fun dir acc ->
      let path = File_tree.Dir.path dir in
      Cont
        (Pset.union acc
           (File_tree.Dir.files dir
            |> String_set.elements
            |> List.map ~f:(Path.relative path)
            |> Pset.of_list)))
  in
  let all_copy_targets =
    List.fold_left contexts ~init:Pset.empty ~f:(fun acc (ctx : Context.t) ->
      Pset.union acc (Pset.elements all_source_files
                      |> List.map ~f:(Path.append ctx.build_dir)
                      |> Pset.of_list))
  in
  let all_other_targets =
    List.fold_left rules ~init:Pset.empty ~f:(fun acc { Pre_rule.targets; _ } ->
      Pset.union acc targets)
  in
  let all_targets_by_dir = lazy (
    Pset.elements (Pset.union all_copy_targets all_other_targets)
    |> List.filter_map ~f:(fun path ->
      if Path.is_root path then
        None
      else
        Some (Path.parent path, path))
    |> Pmap.of_alist_multi
    |> Pmap.map ~f:Pset.of_list
  ) in
  let t =
    { contexts
    ; files      = Hashtbl.create 1024
    ; trace      = Trace.load ()
    ; timestamps = Hashtbl.create 1024
    ; local_mkdirs = Path.Local.Set.empty
    ; all_targets_by_dir
    } in
  List.iter rules ~f:(compile_rule t ~allow_override:false);
  setup_copy_rules t
    ~all_non_target_source_files:
      (Pset.diff all_source_files all_other_targets);
  at_exit (fun () -> Trace.dump t.trace);
  t

let remove_old_artifacts t =
  let rec walk dir =
    let keep =
      Path.readdir dir
      |> List.filter ~f:(fun fn ->
        let fn = Path.relative dir fn in
        match Unix.lstat (Path.to_string fn) with
        | { st_kind = S_DIR; _ } ->
          walk fn
        | exception _ ->
          let keep = Hashtbl.mem t.files fn in
          if not keep then Path.unlink fn;
          keep
        | _ ->
          let keep = Hashtbl.mem t.files fn in
          if not keep then Path.unlink fn;
          keep)
      |> function
      | [] -> false
      | _  -> true
    in
    if not keep then Path.rmdir dir;
    keep
  in
  let walk dir =
    if Path.exists dir then ignore (walk dir : bool)
  in
  List.iter t.contexts ~f:(fun (ctx : Context.t) ->
    walk ctx.build_dir;
    walk (Config.local_install_dir ~context:ctx.name);
  )

let do_build_exn t targets =
  remove_old_artifacts t;
  all_unit (List.map targets ~f:(fun fn -> wait_for_file t fn ~targeting:fn))

let do_build t targets =
  try
    Ok (do_build_exn t targets)
  with Build_error.E e ->
    Error e

(* For [jbuilder external-lib-deps] *)
module Approx_deps = struct
  open Build.Primitive
  open Build.Repr

  let collect bs t =
    let deps = ref Pset.empty in
    let lib_deps = ref Pmap.empty in
    let rec exec : type a. a t -> a = fun t ->
      match t with
      | Return x -> x
      | Bind (t, f) -> exec (f (exec t))
      | Map  (t, f) -> f (exec t)
      | Both (t1, t2) -> (exec t1, exec t2)
      | Contents path -> deps := Pset.add path !deps; Not_building
      | Lines_of path -> deps := Pset.add path !deps; Not_building
      | Fail _ -> ()
      | Memo m -> begin
          match m.state with
          | Evaluated x -> x
          | Evaluating ->
            die "Dependency cycle evaluating memoized build arrow %s" m.name
          | Unevaluated ->
            m.state <- Evaluating;
            let x = exec m.t in
            m.state <- Evaluated x;
            x
        end
      | Prim prim ->
        match prim with
        | Paths ps -> deps := Pset.union !deps ps; ()
        | Glob (dir, re) ->
          (match Pmap.find dir (Lazy.force bs.all_targets_by_dir) with
           | None -> Pset.empty
           | Some targets ->
             Pset.filter targets ~f:(fun path ->
               Re.execp re (Path.basename path)))
        | File_exists p ->
          let dir = Path.parent p in
          let targets =
            Option.value (Pmap.find dir (Lazy.force bs.all_targets_by_dir))
              ~default:Pset.empty
          in
          Pset.mem p targets
        | Record_lib_deps (dir, deps) ->
          let data =
            match Pmap.find dir !lib_deps with
            | None -> deps
            | Some others -> Build.merge_lib_deps deps others
          in
          lib_deps := Pmap.add !lib_deps ~key:dir ~data
    in
    ignore (exec (Build.repr t));
    (!deps, !lib_deps)
end

let rules_for_targets t targets =
  let cache = Hashtbl.create 1024 in
  let rules_for_files t paths =
    List.filter_map paths ~f:(fun path ->
      match Hashtbl.find t.files path with
      | None -> None
      | Some rule ->
        let deps, lib_deps =
          Hashtbl.find_or_add cache path ~f:(fun _ ->
            Approx_deps.collect t rule.Rule.build)
        in
        Some (path, rule, deps, lib_deps))
  in
  let module File_closure =
    Top_closure.Make(Path)
      (struct
        type graph = t
        type t = Path.t * Rule.t * Path.Set.t * Build.lib_deps Pmap.t
        let key (path, _, _, _) = path
        let deps (_, _, deps, _) bs = rules_for_files bs (Pset.elements deps)
      end)
  in
  match File_closure.top_closure t (rules_for_files t targets) with
  | Ok l -> l
  | Error cycle ->
    die "dependency cycle detected:\n   %s"
      (List.map cycle ~f:(fun (path, _, _, _) -> Path.to_string path)
       |> String.concat ~sep:"\n-> ")

let all_lib_deps t targets =
  List.fold_left (rules_for_targets t targets) ~init:Pmap.empty
    ~f:(fun acc (_, _, _, lib_deps) ->
      Pmap.merge acc lib_deps ~f:(fun _ a b ->
        match a, b with
        | None, None -> None
        | Some a, None -> Some a
        | None, Some b -> Some b
        | Some a, Some b -> Some (Build.merge_lib_deps a b)))

let all_lib_deps_by_context t targets =
  List.fold_left (rules_for_targets t targets) ~init:[] ~f:(fun acc (_, _, _, lib_deps) ->
    Path.Map.fold lib_deps ~init:acc ~f:(fun ~key:path ~data:lib_deps acc ->
      match Path.extract_build_context path with
      | None -> acc
      | Some (context, _) -> (context, lib_deps) :: acc))
  |> String_map.of_alist_multi
  |> String_map.map ~f:(function
    | [] -> String_map.empty
    | x :: l -> List.fold_left l ~init:x ~f:Build.merge_lib_deps)
